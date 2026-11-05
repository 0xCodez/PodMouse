// Bakes one AirPods 4 earbud from signed distance fields into a compact mesh.
// Units are millimetres. Head at the origin, stem along -Y, speaker toward +X+Z.
import { mkdirSync, writeFileSync } from 'node:fs'
import { edgeTable, triTable } from 'three/addons/objects/MarchingCubes.js'

const STEP = 0.25
const BOUNDS = { min: [-13, -24, -13], max: [15, 12.5, 16] }

const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
const len = (a) => Math.hypot(a[0], a[1], a[2])
const unit = (a) => { const l = len(a); return [a[0] / l, a[1] / l, a[2] / l] }
const add = (a, b, s = 1) => [a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s]
const mix = (a, b, t) => a + (b - a) * t
const clamp = (x, a, b) => Math.min(b, Math.max(a, x))

const smoothMin = (a, b, k) => {
  const h = clamp(0.5 + (0.5 * (b - a)) / k, 0, 1)
  return mix(b, a, h) - k * h * (1 - h)
}
const smoothMax = (a, b, k) => -smoothMin(-a, -b, k)

const ellipsoid = (p, c, r) => {
  const q = sub(p, c)
  const k0 = Math.hypot(q[0] / r[0], q[1] / r[1], q[2] / r[2])
  const k1 = Math.hypot(q[0] / (r[0] * r[0]), q[1] / (r[1] * r[1]), q[2] / (r[2] * r[2]))
  return k1 < 1e-9 ? -Math.min(...r) : (k0 * (k0 - 1)) / k1
}

// Cone with rounded ends, flattened on one axis by `squash` around the segment.
const roundCone = (p, a, b, ra, rb, squashX = 1) => {
  const q = [(p[0] - a[0]) / squashX + a[0], p[1], p[2]]
  const ba = sub(b, a), pa = sub(q, a)
  const t = clamp(dot(pa, ba) / dot(ba, ba), 0, 1)
  return len(add(pa, ba, -t)) - mix(ra, rb, t)
}

const plane = (p, c, n) => dot(sub(p, c), n)

// Speaker nozzle axis: angled forward and inward, as it sits in the ear canal.
const nozzleDir = unit([0.46, 0.26, 0.85])
const nozzleBase = add([0, 0.4, 0], nozzleDir, 2.5)
const nozzleTip = add([0, 0.4, 0], nozzleDir, 6.9)
const grilleCenter = add(nozzleTip, nozzleDir, 3.2)

const stemTop = [0.2, -5.5, -1.4]
const stemBottom = [0.1, -20.2, -3.3]
const stemDir = unit(sub(stemBottom, stemTop))
const stemEnd = add(stemBottom, stemDir, 2.0)

const ventCenter = [-8.4, 1.8, -3.9]
const ventDir = unit([-0.86, 0.2, -0.46])
const topVent = [0.6, 8.05, -4.2]

function housing(p) {
  let d = ellipsoid(p, [0, 0, 0], [8.9, 8.5, 8.7])
  // A bulge behind the speaker gives the head its asymmetric teardrop.
  d = smoothMin(d, ellipsoid(p, [-1.2, -1.6, -2], [7.8, 7.6, 7.4]), 2.5)
  d = smoothMin(d, roundCone(p, nozzleBase, nozzleTip, 6.6, 5.8), 4.5)
  d = smoothMax(d, plane(p, grilleCenter, nozzleDir), 2.2)

  let stem = roundCone(p, stemTop, stemBottom, 3.7, 2.85, 1.1)
  stem = smoothMax(stem, plane(p, stemEnd, stemDir), 0.9)
  d = smoothMin(d, stem, 3.4)
  return d
}

const grilleRecess = (p) => ellipsoid(p, add(grilleCenter, nozzleDir, 0.25), [2.8, 3.5, 2.8])
const micRecess = (p) => ellipsoid(p, stemEnd, [2.1, 0.8, 1.7])
const ventRecess = (p) => ellipsoid(p, ventCenter, [1.1, 2.7, 1.1])
const topVentRecess = (p) => ellipsoid(p, topVent, [2.2, 0.7, 1.1])
const pressPad = (p) => roundCone(p, [-3.55, -11.5, -2.6], [-3.3, -17, -3.2], 0.7, 0.7)

function shell(p) {
  let d = housing(p)
  d = smoothMax(d, -(grilleRecess(p) + 0.05), 0.55)
  d = smoothMax(d, -micRecess(p), 0.25)
  d = smoothMax(d, -ventRecess(p), 0.22)
  d = smoothMax(d, -topVentRecess(p), 0.22)
  d = smoothMax(d, -pressPad(p), 1.1)
  return d
}

// The dark inserts sit just under the shell, seen through its recesses.
function inserts(p) {
  const cushion = housing(p) + 0.32
  const keep = Math.min(grilleRecess(p) - 0.5, micRecess(p) - 0.15, ventRecess(p) - 0.15, topVentRecess(p) - 0.15)
  return Math.max(cushion, keep)
}

function polygonize(sdf) {
  const size = [0, 1, 2].map((i) => Math.ceil((BOUNDS.max[i] - BOUNDS.min[i]) / STEP) + 1)
  const [nx, ny, nz] = size
  const at = (x, y, z) => x + y * nx + z * nx * ny
  const field = new Float32Array(nx * ny * nz)
  for (let z = 0; z < nz; z++) for (let y = 0; y < ny; y++) for (let x = 0; x < nx; x++) {
    field[at(x, y, z)] = sdf([BOUNDS.min[0] + x * STEP, BOUNDS.min[1] + y * STEP, BOUNDS.min[2] + z * STEP])
  }

  const position = (x, y, z) => [BOUNDS.min[0] + x * STEP, BOUNDS.min[1] + y * STEP, BOUNDS.min[2] + z * STEP]
  const corners = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]]
  const edges = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
  const vertices = []
  const indices = []
  const lookup = new Map()

  const vertexOn = (x, y, z, edge, values) => {
    const [ca, cb] = edges[edge]
    const a = corners[ca], b = corners[cb]
    const ia = at(x + a[0], y + a[1], z + a[2]), ib = at(x + b[0], y + b[1], z + b[2])
    const key = ia < ib ? ia * 1e8 + ib : ib * 1e8 + ia
    let index = lookup.get(key)
    if (index === undefined) {
      const t = values[ca] / (values[ca] - values[cb])
      const pa = position(x + a[0], y + a[1], z + a[2]), pb = position(x + b[0], y + b[1], z + b[2])
      index = vertices.length
      vertices.push([mix(pa[0], pb[0], t), mix(pa[1], pb[1], t), mix(pa[2], pb[2], t)])
      lookup.set(key, index)
    }
    return index
  }

  for (let z = 0; z < nz - 1; z++) for (let y = 0; y < ny - 1; y++) for (let x = 0; x < nx - 1; x++) {
    const values = corners.map((c) => field[at(x + c[0], y + c[1], z + c[2])])
    let cube = 0
    values.forEach((v, i) => { if (v < 0) cube |= 1 << i })
    if (edgeTable[cube] === 0) continue
    for (let i = cube * 16; triTable[i] !== -1; i += 3) {
      const tri = [triTable[i], triTable[i + 1], triTable[i + 2]].map((e) => vertexOn(x, y, z, e, values))
      indices.push(tri[0], tri[2], tri[1])
    }
  }

  // Normals from the field itself, so facets never show, at any zoom.
  const normals = vertices.map((p) => {
    const e = 0.08
    return unit([
      sdf([p[0] + e, p[1], p[2]]) - sdf([p[0] - e, p[1], p[2]]),
      sdf([p[0], p[1] + e, p[2]]) - sdf([p[0], p[1] - e, p[2]]),
      sdf([p[0], p[1], p[2] + e]) - sdf([p[0], p[1], p[2] - e]),
    ])
  })
  return { vertices, normals, indices }
}

// Layout: u32 vertex count, u32 index count, then Int16 xyz, Int8 xyz (padded), Uint32 indices.
function encode({ vertices, normals, indices }) {
  const positionBytes = vertices.length * 6
  const normalBytes = vertices.length * 3
  const padding = (4 - ((positionBytes + normalBytes) % 4)) % 4
  const buffer = new ArrayBuffer(8 + positionBytes + normalBytes + padding + indices.length * 4)
  new Uint32Array(buffer, 0, 2).set([vertices.length, indices.length])
  new Int16Array(buffer, 8, vertices.length * 3).set(vertices.flat().map((v) => Math.round(v * 500)))
  new Int8Array(buffer, 8 + positionBytes, vertices.length * 3).set(normals.flat().map((v) => Math.round(v * 127)))
  new Uint32Array(buffer, 8 + positionBytes + normalBytes + padding, indices.length).set(indices)
  return Buffer.from(buffer)
}

const outDir = new URL('../public/model/', import.meta.url)
mkdirSync(outDir, { recursive: true })
for (const [name, sdf] of [['bud-shell', shell], ['bud-inserts', inserts]]) {
  const started = Date.now()
  const mesh = polygonize(sdf)
  const data = encode(mesh)
  writeFileSync(new URL(`${name}.bin`, outDir), data)
  console.log(name, mesh.vertices.length, 'vertices', (data.length / 1024).toFixed(0), 'KB', Date.now() - started, 'ms')
}
