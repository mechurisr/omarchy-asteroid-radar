.pragma library

// Pure helpers for the near-Earth asteroid radar: API parsing, unit
// conversion, interpolation, and the 3D -> 2D projection the Canvas uses.
// Nothing here touches QML objects, so it is safe to call from bindings.

var AU_KM = 149597870.7
var LD_KM = 384400
var AU_LD = AU_KM / LD_KM
var DAY_MS = 86400000
var HOUR_MS = 3600000

// ------------------------------------------------------------- time

function jdToMs(jd) {
  // JPL hands out TDB Julian dates; TDB runs ~69 s ahead of UTC, which is
  // invisible at the scale of this map.
  return (Number(jd) - 2440587.5) * DAY_MS
}

function msToJd(ms) {
  return ms / DAY_MS + 2440587.5
}

// ------------------------------------------------------------- CAD API

// Converts the JPL close-approach response into plain objects, nearest
// first so a cap keeps the interesting ones.
function parseCad(text) {
  var data = JSON.parse(text)
  if (!data || !data.fields || !data.data) return []
  var idx = {}
  for (var i = 0; i < data.fields.length; i++) idx[data.fields[i]] = i
  var out = []
  for (var j = 0; j < data.data.length; j++) {
    var r = data.data[j]
    var des = String(r[idx.des] || "").trim()
    if (!des) continue
    var h = parseFloat(r[idx.h])
    var diameter = parseFloat(r[idx.diameter])
    out.push({
      des: des,
      name: String(r[idx.fullname] || des).trim().replace(/^\((.*)\)$/, "$1"),
      approachAt: jdToMs(r[idx.jd]),
      distAu: parseFloat(r[idx.dist]),
      distLd: parseFloat(r[idx.dist]) * AU_LD,
      velocity: parseFloat(r[idx.v_rel]),
      h: h,
      diameterKm: !isNaN(diameter) ? diameter : estimateDiameterKm(h),
      diameterMeasured: !isNaN(diameter),
      path: []
    })
  }
  return out
}

// Diameter from absolute magnitude, assuming a typical 0.14 albedo. Real
// albedos span ~0.05-0.25, so this is good to a factor of about two.
function estimateDiameterKm(h) {
  if (isNaN(h)) return NaN
  return 1329 / Math.sqrt(0.14) * Math.pow(10, -h / 5)
}

// ------------------------------------------------------------- Horizons

// Pulls the $$SOE..$$EOE vector rows out of a Horizons JSON response.
// Returns [{t, x, y, z}] in ms and lunar distances, ecliptic frame.
function parseHorizons(text) {
  var result
  try {
    result = JSON.parse(text).result
  } catch (e) {
    return []
  }
  if (!result) return []
  var start = result.indexOf("$$SOE")
  var end = result.indexOf("$$EOE")
  if (start < 0 || end < 0) return []
  var lines = result.slice(start + 5, end).split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var cols = lines[i].split(",")
    if (cols.length < 5) continue
    var jd = parseFloat(cols[0])
    var x = parseFloat(cols[2]), y = parseFloat(cols[3]), z = parseFloat(cols[4])
    if (isNaN(jd) || isNaN(x) || isNaN(y) || isNaN(z)) continue
    out.push({ t: jdToMs(jd), x: x * AU_LD, y: y * AU_LD, z: z * AU_LD })
  }
  return out
}

// Splits a batched fetch ("===key===\n<body>" blocks) back into a map.
function splitSections(text) {
  var out = {}
  var parts = String(text || "").split(/^===(.+)===$/m)
  for (var i = 1; i + 1 < parts.length; i += 2) out[parts[i]] = parts[i + 1]
  return out
}

// Linear interpolation along a time-sorted path. Outside the path the end
// point is held, so callers check `inRange` before drawing a "now" marker.
function positionAt(path, t) {
  if (!path || path.length === 0) return null
  if (t <= path[0].t) return { x: path[0].x, y: path[0].y, z: path[0].z, inRange: t === path[0].t }
  var last = path[path.length - 1]
  if (t >= last.t) return { x: last.x, y: last.y, z: last.z, inRange: t === last.t }
  var lo = 0, hi = path.length - 1
  while (hi - lo > 1) {
    var mid = (lo + hi) >> 1
    if (path[mid].t <= t) lo = mid
    else hi = mid
  }
  var a = path[lo], b = path[hi]
  var f = (t - a.t) / (b.t - a.t)
  return {
    x: a.x + (b.x - a.x) * f,
    y: a.y + (b.y - a.y) * f,
    z: a.z + (b.z - a.z) * f,
    inRange: true
  }
}

function length3(p) {
  return Math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
}

// ------------------------------------------------------------- projection

// Radial compression. Approaches span 0.5-20 LD while the Moon sits at 1 LD,
// so a linear map would squash the Earth-Moon system into a dot. The log map
// keeps direction and squeezes only the radius.
function scaleRadius(d, logScale, maxLd) {
  if (!logScale) return d / maxLd
  var d0 = 0.5
  return Math.log(1 + d / d0) / Math.log(1 + maxLd / d0)
}

function scalePoint(p, logScale, maxLd) {
  var d = length3(p)
  if (d === 0) return { x: 0, y: 0, z: 0 }
  var k = scaleRadius(d, logScale, maxLd) / d
  return { x: p.x * k, y: p.y * k, z: p.z * k }
}

// Camera: yaw spins around the ecliptic pole (z), pitch tilts the plane
// toward the viewer. Returns screen offsets from centre plus a depth value
// (larger = nearer) for sorting and fading.
function project(p, yaw, pitch, radiusPx, perspective) {
  var cy = Math.cos(yaw), sy = Math.sin(yaw)
  var x1 = p.x * cy - p.y * sy
  var y1 = p.x * sy + p.y * cy
  var cp = Math.cos(pitch), sp = Math.sin(pitch)
  var y2 = y1 * cp - p.z * sp
  var z2 = y1 * sp + p.z * cp
  // y2 points away from the viewer; perspective shrinks far things a little.
  var f = perspective > 0 ? 1 / (1 + y2 * perspective) : 1
  return { sx: x1 * radiusPx * f, sy: -z2 * radiusPx * f, depth: -y2, f: f }
}

// ------------------------------------------------------------- formatting

function fmtLd(ld) {
  if (isNaN(ld)) return "—"
  return ld < 10 ? ld.toFixed(2) + " LD" : ld.toFixed(1) + " LD"
}

function fmtKm(km) {
  if (isNaN(km)) return "—"
  if (km >= 1e6) return (km / 1e6).toFixed(2) + "M km"
  return Math.round(km / 1000) + "k km"
}

function fmtSize(km) {
  if (isNaN(km)) return "?"
  var m = km * 1000
  if (m < 1000) return "~" + Math.round(m) + " m"
  return "~" + km.toFixed(1) + " km"
}

function fmtRelative(at, now) {
  var diff = at - now
  var past = diff < 0
  var s = Math.abs(diff) / 1000
  var text
  if (s < 3600) text = Math.max(1, Math.round(s / 60)) + "m"
  else if (s < 86400) text = Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  else text = Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h"
  return past ? text + " ago" : "in " + text
}

function fmtLocal(at) {
  var d = new Date(at)
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  return days[d.getDay()] + " " + pad(d.getMonth() + 1) + "/" + pad(d.getDate())
    + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
}
