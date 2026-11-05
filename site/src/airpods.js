import * as THREE from 'three'

// The case and earbuds, modelled from AirPods 4 proportions. Units are millimetres.
const CASE = { width: 50.1, height: 46.2, depth: 21.2, seam: 8.6, gap: 0.16 }

const signedPow = (v, p) => Math.sign(v) * Math.abs(v) ** p

export const materials = () => ({
  plastic: new THREE.MeshPhysicalMaterial({
    color: 0xf3f2ef, roughness: 0.3, clearcoat: 1, clearcoatRoughness: 0.14, ior: 1.5, sheen: 0.4, sheenRoughness: 0.6, sheenColor: 0xffffff,
  }),
  gloss: new THREE.MeshPhysicalMaterial({
    color: 0xf7f6f3, roughness: 0.28, clearcoat: 1, clearcoatRoughness: 0.16,
  }),
  inner: new THREE.MeshStandardMaterial({ color: 0xe4e3e0, roughness: 0.62, side: THREE.DoubleSide }),
  dark: new THREE.MeshStandardMaterial({ color: 0x0b0b0c, roughness: 0.82 }),
  mesh: new THREE.MeshStandardMaterial({ color: 0x1a1a1c, roughness: 0.7, metalness: 0.3 }),
  metal: new THREE.MeshStandardMaterial({ color: 0xc9cacc, roughness: 0.26, metalness: 1 }),
  led: new THREE.MeshStandardMaterial({ color: 0x1b1b1b, emissive: 0x35ff7a, emissiveIntensity: 0, roughness: 0.3 }),
})

// One horizontal slice of the squircle body at parameter u (−π/2 bottom … π/2 top).
function slice(u) {
  const c = Math.max(Math.cos(u), 0)
  return {
    y: (CASE.height / 2) * signedPow(Math.sin(u), 2 / 3.1),
    halfWidth: (CASE.width / 2) * c ** (2 / 3.1),
    halfDepth: (CASE.depth / 2) * c ** (2 / 4.4),
  }
}

const SIDES = 180

function ringPoint(s, a, scale = 1) {
  const p = 2 / 2.7
  return new THREE.Vector3(s.halfWidth * scale * signedPow(Math.cos(a), p), s.y, s.halfDepth * scale * signedPow(Math.sin(a), p))
}

function loft(rings) {
  const positions = []
  const indices = []
  rings.forEach((ring) => {
    for (let i = 0; i <= SIDES; i++) {
      const point = ringPoint(ring, (i / SIDES) * Math.PI * 2, ring.scale ?? 1)
      positions.push(point.x, point.y, point.z)
    }
  })
  for (let r = 0; r < rings.length - 1; r++) {
    for (let i = 0; i < SIDES; i++) {
      const a = r * (SIDES + 1) + i, b = a + SIDES + 1
      indices.push(a, b, a + 1, b, b + 1, a + 1)
    }
  }
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3))
  geometry.setIndex(indices)
  geometry.computeVertexNormals()
  // The ring seam at angle 0 must share a normal or it shows as a line.
  const normals = geometry.attributes.normal
  for (let r = 0; r < rings.length; r++) {
    const a = r * (SIDES + 1), b = a + SIDES
    const n = new THREE.Vector3().fromBufferAttribute(normals, a).add(new THREE.Vector3().fromBufferAttribute(normals, b)).normalize()
    normals.setXYZ(a, n.x, n.y, n.z)
    normals.setXYZ(b, n.x, n.y, n.z)
  }
  return geometry
}

const seamU = Math.asin(signedPow((CASE.seam / CASE.height) * 2, 3.1 / 2))

function shellRings(from, to, count, lipAtEnd) {
  const rings = []
  for (let i = 0; i <= count; i++) rings.push(slice(from + ((to - from) * i) / count))
  // A tiny radius into the parting line, the way moulded parts meet.
  const edge = rings[lipAtEnd ? rings.length - 1 : 0]
  const dir = lipAtEnd ? 1 : -1
  const lip = [
    { ...edge, y: edge.y + dir * 0.1, scale: 0.9975 },
    { ...edge, y: edge.y + dir * 0.16, scale: 0.992 },
    { ...edge, y: edge.y + dir * 0.17, scale: 0.97 },
  ]
  return lipAtEnd ? [...rings, ...lip] : [...lip.reverse(), ...rings]
}

function capGeometry(s, scale, y, facing = 1) {
  const shape = new THREE.Shape()
  const steps = 96
  for (let i = 0; i <= steps; i++) {
    const p = ringPoint(s, (i / steps) * Math.PI * 2, scale)
    if (i === 0) shape.moveTo(p.x, p.z)
    else shape.lineTo(p.x, p.z)
  }
  const geometry = new THREE.ShapeGeometry(shape, 96)
  geometry.rotateX((-Math.PI / 2) * facing)
  geometry.translate(0, y, 0)
  return geometry
}

function stadium(width, height) {
  const r = height / 2
  const shape = new THREE.Shape()
  shape.moveTo(-width / 2 + r, -r)
  shape.lineTo(width / 2 - r, -r)
  shape.absarc(width / 2 - r, 0, r, -Math.PI / 2, Math.PI / 2, false)
  shape.lineTo(-width / 2 + r, r)
  shape.absarc(-width / 2 + r, 0, r, Math.PI / 2, Math.PI * 1.5, false)
  return shape
}

async function loadMesh(url) {
  const buffer = await (await fetch(url)).arrayBuffer()
  const [vertexCount, indexCount] = new Uint32Array(buffer, 0, 2)
  const positions = new Int16Array(buffer, 8, vertexCount * 3)
  const normalsOffset = 8 + vertexCount * 6
  const normals = new Int8Array(buffer, normalsOffset, vertexCount * 3)
  const indicesOffset = Math.ceil((normalsOffset + vertexCount * 3) / 4) * 4
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute('position', new THREE.BufferAttribute(Float32Array.from(positions, (v) => v / 500), 3))
  geometry.setAttribute('normal', new THREE.BufferAttribute(normals, 3, true))
  geometry.setIndex(new THREE.BufferAttribute(new Uint32Array(buffer, indicesOffset, indexCount), 1))
  return geometry
}

/** Resolves the two baked earbud meshes, relative to the site's base URL. */
export async function loadBudGeometry(base = import.meta.env?.BASE_URL ?? '/') {
  const [shell, inserts] = await Promise.all([loadMesh(`${base}model/bud-shell.bin`), loadMesh(`${base}model/bud-inserts.bin`)])
  return { shell, inserts }
}

export function createBud(geometry, mats, side = 1) {
  const bud = new THREE.Group()
  bud.add(new THREE.Mesh(geometry.shell, mats.gloss), new THREE.Mesh(geometry.inserts, mats.mesh))
  bud.scale.x = side
  return bud
}

/** The case. `setLid(0…1)` opens it around the rear hinge; the LED sits on the front. */
export function createCase(budGeometry, mats) {
  const root = new THREE.Group()
  const halfPi = Math.PI / 2
  const seamSlice = slice(seamU)

  const body = new THREE.Mesh(loft(shellRings(-halfPi + 0.0005, seamU, 120, true)), mats.plastic)
  const hingeY = CASE.seam, hingeZ = -seamSlice.halfDepth + 0.6
  const lid = new THREE.Group()
  lid.position.set(0, hingeY, hingeZ)
  const lidShell = new THREE.Mesh(loft(shellRings(seamU, halfPi - 0.0005, 80, false)), mats.plastic)
  lidShell.position.set(0, CASE.gap - hingeY, -hingeZ)
  lid.add(lidShell)

  // Hollow lid: a thin wall running from the parting line up into a shallow dome.
  const lidCavity = []
  for (let i = 0; i <= 40; i++) {
    const ring = slice(seamU + ((halfPi - 0.04 - seamU) * i) / 40)
    lidCavity.push({ ...ring, scale: 0.955 })
  }
  const lidInner = new THREE.Mesh(loft(lidCavity), mats.inner)
  lidInner.position.set(0, CASE.gap + 0.17 - hingeY, -hingeZ)
  const lidCeiling = new THREE.Mesh(capGeometry(lidCavity.at(-1), 0.955, lidCavity.at(-1).y, -1), mats.inner)
  lidCeiling.position.copy(lidInner.position)
  const lidRim = new THREE.Mesh(loft([{ ...seamSlice, scale: 0.97 }, { ...seamSlice, scale: 0.955 }]), mats.inner)
  lidRim.position.copy(lidInner.position)
  lid.add(lidInner, lidCeiling, lidRim)

  // The tray sits a little below the rim, so the earbuds look docked rather than placed.
  const DECK_DROP = 1.3
  const deck = new THREE.Mesh(capGeometry(seamSlice, 0.955, CASE.seam - DECK_DROP), mats.inner)
  const deckWall = new THREE.Mesh(
    loft([
      { ...seamSlice, y: CASE.seam + 0.17, scale: 0.97 },
      { ...seamSlice, y: CASE.seam + 0.1, scale: 0.955 },
      { ...seamSlice, y: CASE.seam - DECK_DROP, scale: 0.955 },
    ]),
    mats.inner,
  )
  deckWall.material = mats.inner
  const wellShape = (x) => {
    const well = new THREE.Mesh(new THREE.CircleGeometry(7.4, 64), mats.dark)
    well.rotation.x = -Math.PI / 2
    well.position.set(x, CASE.seam - DECK_DROP + 0.04, 0.1)
    well.scale.set(1.2, 1.1, 1)
    return well
  }
  const hinge = new THREE.Mesh(new THREE.CapsuleGeometry(1.15, 17, 12, 32), mats.metal)
  hinge.rotation.z = halfPi
  hinge.position.set(0, CASE.seam + CASE.gap / 2 - 0.3, -seamSlice.halfDepth + 0.68)

  const buds = new THREE.Group()
  for (const side of [1, -1]) {
    // Stem down into the case, speaker facing the other earbud and angled up.
    const bud = createBud(budGeometry, mats, side)
    bud.rotation.y = side * 1.04
    const dock = new THREE.Group()
    dock.add(bud)
    dock.rotation.z = side * 0.34
    dock.position.set(-side * 13.1, CASE.seam + 0.2, 0.4)
    buds.add(dock)
  }

  const led = new THREE.Mesh(new THREE.SphereGeometry(0.62, 32, 16), mats.led)
  led.scale.z = 0.14
  const front = slice(Math.asin(signedPow((-6 / CASE.height) * 2, 3.1 / 2)))
  led.position.set(0, -6, front.halfDepth + 0.015)

  const usb = new THREE.Group()
  const port = new THREE.Mesh(new THREE.ShapeGeometry(stadium(8.9, 3.3), 32), mats.metal)
  const socket = new THREE.Mesh(new THREE.ShapeGeometry(stadium(8.3, 2.7), 32), mats.dark)
  const tongue = new THREE.Mesh(new THREE.ShapeGeometry(stadium(6.6, 0.8), 16), mats.metal)
  socket.position.z = 0.01
  tongue.position.z = 0.02
  usb.add(port, socket, tongue)
  usb.rotation.x = halfPi
  usb.position.set(0, -CASE.height / 2 - 0.02, 0)

  root.add(body, lid, deck, deckWall, wellShape(12), wellShape(-12), hinge, buds, led, usb)
  root.userData.lid = lid
  root.userData.buds = buds
  root.userData.shells = [body, lidShell]
  root.userData.opening = new THREE.Vector3(0, CASE.seam, 0.4)
  root.userData.setLid = (open) => { lid.rotation.x = -open * 1.9 }
  root.userData.setLed = (level) => { mats.led.emissiveIntensity = level * 6 }
  return root
}

/** A studio of soft boxes, so white plastic picks up long, clean highlights. */
export function studioEnvironment(renderer) {
  const room = new THREE.Scene()
  room.background = new THREE.Color(0x0b0b0d)
  const panel = (w, h, position, intensity, tint = 0xffffff) => {
    const mesh = new THREE.Mesh(
      new THREE.PlaneGeometry(w, h),
      new THREE.MeshBasicMaterial({ color: new THREE.Color(tint).multiplyScalar(intensity), side: THREE.DoubleSide }),
    )
    mesh.position.set(...position)
    mesh.lookAt(0, 0, 0)
    room.add(mesh)
  }
  panel(14, 7, [0, 11, 3], 3.4)
  panel(5, 16, [-13, 2, 4], 2.2)
  panel(5, 16, [13, 2, 4], 2.2)
  panel(18, 3, [0, 1, 14], 0.9)
  panel(18, 6, [0, -12, 0], 0.5, 0xdfe6f2)
  panel(10, 10, [0, 5, -14], 1.6, 0xe8eeff)

  const pmrem = new THREE.PMREMGenerator(renderer)
  const texture = pmrem.fromScene(room, 0.045).texture
  pmrem.dispose()
  return texture
}

/**
 * A bright white cove for the site's light pages. White plastic on a white page disappears
 * unless something dark reflects in it, so black flags sit where the silhouette looks, the way
 * product photographers shoot white on white. Two faint gels tie the case to the page's glow.
 */
export function daylightEnvironment(renderer) {
  const room = new THREE.Scene()
  room.background = new THREE.Color(0xdfe2ea).multiplyScalar(0.34)
  const panel = (w, h, position, intensity, tint = 0xffffff) => {
    const mesh = new THREE.Mesh(
      new THREE.PlaneGeometry(w, h),
      new THREE.MeshBasicMaterial({ color: new THREE.Color(tint).multiplyScalar(intensity), side: THREE.DoubleSide }),
    )
    mesh.position.set(...position)
    mesh.lookAt(0, 0, 0)
    room.add(mesh)
  }
  panel(26, 16, [0, 13, 4], 3.1)
  panel(9, 22, [-15, 3, 7], 2.3)
  panel(7, 22, [15, 2, 9], 1.5)
  panel(30, 12, [0, 2, 16], 0.85)
  panel(4, 26, [-13, 0, -10], 0.03)
  panel(4, 26, [13, 0, -10], 0.03)
  panel(34, 6, [0, -3, -14], 0.04)
  panel(34, 14, [0, -13, 2], 0.95, 0xdfe4f2)
  panel(6, 10, [10, 8, -10], 2.6, 0xffb3d6)
  panel(6, 10, [-11, 7, -9], 2.6, 0x9cc4ff)

  const pmrem = new THREE.PMREMGenerator(renderer)
  const texture = pmrem.fromScene(room, 0.03).texture
  pmrem.dispose()
  return texture
}

export function createStage(canvas, { alpha = false, antialias = true, daylight = false } = {}) {
  const renderer = new THREE.WebGLRenderer({
    canvas, alpha, antialias, powerPreference: 'high-performance',
    preserveDrawingBuffer: alpha && !daylight, premultipliedAlpha: daylight,
  })
  renderer.outputColorSpace = THREE.SRGBColorSpace
  renderer.toneMapping = daylight ? THREE.NeutralToneMapping : THREE.ACESFilmicToneMapping
  renderer.toneMappingExposure = daylight ? 0.98 : 1.05
  const scene = new THREE.Scene()
  scene.environment = daylight ? daylightEnvironment(renderer) : studioEnvironment(renderer)
  scene.environmentIntensity = daylight ? 0.98 : 1.5
  const camera = new THREE.PerspectiveCamera(24, 1, 1, 800)
  return { renderer, scene, camera }
}
