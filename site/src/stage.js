import * as THREE from 'three'
import { createCase, createStage, loadBudGeometry, materials } from './airpods.js'

// The site's 3D layer: the case on a transparent canvas, with its shadows and lens flares.
const FOV = 24
const DISTANCE = 235
const VIEW_HEIGHT = 2 * DISTANCE * Math.tan(THREE.MathUtils.degToRad(FOV / 2))
const CASE_HEIGHT = 46.2

const KEY = new THREE.Vector3(-0.45, 0.8, 0.55).normalize()
const FRONT = new THREE.Vector3(-0.3, 0.32, 0.9).normalize()
const SHININESS = 90
const SAMPLES = 1500

const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x))
const lerp = (a, b, t) => a + (b - a) * t
const smooth = (x) => x * x * (3 - 2 * x)
const number = (v, fallback) => (Number.isFinite(v) ? v : fallback)

const vertex = /* glsl */`
  varying vec2 vUv;
  void main() { vUv = position.xy * 0.5 + 0.5; gl_Position = vec4(position.xy, 0.0, 1.0); }
`

function fullscreen(material) {
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array([-1, -1, 0, 3, -1, 0, -1, 3, 0]), 3))
  const mesh = new THREE.Mesh(geometry, material)
  mesh.frustumCulled = false
  const scene = new THREE.Scene()
  scene.add(mesh)
  return { scene, mesh }
}

const overlay = (uniforms, fragmentShader) => new THREE.ShaderMaterial({
  uniforms, vertexShader: vertex, fragmentShader, transparent: true, premultipliedAlpha: true,
  depthTest: false, depthWrite: false, toneMapped: false,
})

const blurShader = /* glsl */`
  varying vec2 vUv;
  uniform sampler2D tMap;
  uniform vec2 uStep;
  void main() {
    float sum = texture2D(tMap, vUv).a * 0.1964;
    sum += (texture2D(tMap, vUv + uStep * 1.41).a + texture2D(tMap, vUv - uStep * 1.41).a) * 0.2969;
    sum += (texture2D(tMap, vUv + uStep * 3.29).a + texture2D(tMap, vUv - uStep * 3.29).a) * 0.0945;
    sum += (texture2D(tMap, vUv + uStep * 5.18).a + texture2D(tMap, vUv - uStep * 5.18).a) * 0.0104;
    gl_FragColor = vec4(sum);
  }
`

const shadowShader = /* glsl */`
  varying vec2 vUv;
  uniform sampler2D tTight;
  uniform sampler2D tWide;
  uniform float uGround;
  uniform float uWall;
  uniform float uAura;
  uniform float uAspect;
  uniform float uTime;
  uniform vec3 uCase; // centre x, centre y, half height, all in uv

  // The only colour on the page sits in the first few pixels around the case's real outline.
  vec3 flow(float t) {
    t = fract(t) * 4.0;
    float f = smoothstep(0.0, 1.0, fract(t));
    if (t < 1.0) return mix(vec3(0.15, 0.83, 1.0), vec3(0.18, 0.36, 1.0), f);
    if (t < 2.0) return mix(vec3(0.18, 0.36, 1.0), vec3(0.54, 0.3, 1.0), f);
    if (t < 3.0) return mix(vec3(0.54, 0.3, 1.0), vec3(1.0, 0.24, 0.6), f);
    return mix(vec3(1.0, 0.24, 0.6), vec3(0.15, 0.83, 1.0), f);
  }

  void main() {
    vec2 wallUv = vUv + vec2(0.0, uCase.z * 0.2);
    float wall = texture2D(tWide, wallUv).a * uWall * 0.14;

    // On the floor: the case's width from its silhouette, with the depth of a soft gaussian.
    float floorY = uCase.y - uCase.z * 1.08;
    float offset = vUv.y - floorY;
    float width = texture2D(tWide, vec2(uCase.x + (vUv.x - uCase.x) * 0.9, uCase.y)).a;
    float depth = uCase.z * uCase.z * max(width, 0.001);
    float ground = width * width * (0.3 * exp(-offset * offset / (depth * 0.014)) + 0.18 * exp(-offset * offset / (depth * 0.07))) * uGround;

    float shade = 1.0 - (1.0 - wall) * (1.0 - ground);
    vec4 color = vec4(vec3(0.075, 0.095, 0.2) * shade, shade);

    if (uAura > 0.001) {
      vec2 fromCentre = (vUv - uCase.xy) * vec2(uAspect, 1.0);
      float t = atan(fromCentre.y, fromCentre.x) / 6.2831853 + uTime * 0.05;
      float tight = texture2D(tTight, vUv).a;
      float halo = (0.8 * smoothstep(0.0, 0.5, tight) + 0.2 * texture2D(tWide, vUv).a) * uAura;
      color = vec4(flow(t) * halo, halo) + color * (1.0 - halo);
    }
    gl_FragColor = color;
  }
`

const flareShader = /* glsl */`
  varying vec2 vUv;
  uniform vec4 uFlares[3]; // ndc x, ndc y, strength, size
  uniform float uAspect;
  uniform float uPixel;
  uniform float uTime;

  const vec3 ICE = vec3(0.56, 0.86, 1.0);
  const vec3 COBALT = vec3(0.14, 0.34, 1.0);
  const vec3 VIOLET = vec3(0.5, 0.26, 1.0);
  const vec3 ROSE = vec3(1.0, 0.3, 0.62);

  vec4 over(vec4 top, vec4 under) { return top + under * (1.0 - top.a); }
  vec4 paint(vec3 color, float amount) { return vec4(color * amount, amount); }
  float gauss(float x, float w) { return exp(-(x * x) / (w * w)); }

  void main() {
    vec2 p = vUv * 2.0 - 1.0;
    vec4 color = vec4(0.0);
    for (int i = 0; i < 3; i++) {
      float strength = uFlares[i].z;
      if (strength < 0.004) continue;
      float size = uFlares[i].w;
      vec2 d = p - uFlares[i].xy;
      d.x *= uAspect;
      float ax = abs(d.x);
      float shimmer = 0.92 + 0.08 * sin(uTime * 1.7 + float(i) * 2.1);


      // The wide soft band first, then the hairline over it, each fading along its length.
      float reach = 0.46 * size;
      float band = gauss(d.y, 0.024 * size) * exp(-ax / (reach * 0.36));
      vec3 bandTint = mix(ICE, COBALT, smoothstep(0.0, 0.34 * size, ax));
      color = over(paint(bandTint, 0.34 * strength * band * shimmer), color);

      float fringe = uPixel * 1.6;
      float roseLine = gauss(d.y - fringe, uPixel * 1.05) * exp(-ax / (reach * 0.44)) * smoothstep(0.02, 0.2, ax);
      float blueLine = gauss(d.y + fringe, uPixel * 1.05) * exp(-ax / (reach * 0.5)) * smoothstep(0.02, 0.2, ax);
      color = over(paint(ROSE, 0.42 * strength * roseLine), color);
      color = over(paint(VIOLET, 0.5 * strength * blueLine), color);

      float line = gauss(d.y, uPixel * 1.1) * exp(-ax / reach) * smoothstep(1.25 * size, 0.3 * size, ax);
      vec3 lineTint = mix(mix(vec3(1.0), ICE, smoothstep(0.0, 0.12 * size, ax)), COBALT, smoothstep(0.08 * size, 0.62 * size, ax));
      color = over(paint(lineTint, 0.95 * strength * line), color);

      // A halo tinted at its edge, and a core that stays white.
      float r = length(d);
      color = over(paint(COBALT, 0.13 * strength * exp(-r / (0.05 * size))), color);
      color = over(paint(vec3(1.0), strength * (0.9 * exp(-r / (0.013 * size)) + 0.4 * exp(-r / (0.032 * size)))), color);
    }
    gl_FragColor = vec4(min(color.rgb, vec3(color.a)), clamp(color.a, 0.0, 1.0));
  }
`

// Every stride-th vertex of a shell, in its own space, for finding where a highlight really sits.
// The tiny radius at the parting line would catch every light, so `keep` leaves it out.
function sampleShell(mesh, keep) {
  const position = mesh.geometry.attributes.position, normal = mesh.geometry.attributes.normal
  const stride = Math.max(1, Math.floor(position.count / SAMPLES)) | 1
  const points = [], normals = []
  for (let v = 0; v < position.count; v += stride) {
    if (!keep(position.getY(v))) continue
    points.push(position.getX(v), position.getY(v), position.getZ(v))
    normals.push(normal.getX(v), normal.getY(v), normal.getZ(v))
  }
  return { mesh, points: new Float32Array(points), normals: new Float32Array(normals), count: points.length / 3 }
}

// The brightest place on a shell for a light, as a weighted centre so it slides instead of jumping.
function findHighlight(shell, light, camera, out) {
  const m = shell.mesh.matrixWorld.elements
  const { points, normals, count } = shell
  const cx = camera.position.x, cy = camera.position.y, cz = camera.position.z
  let sum = 0, sx = 0, sy = 0, sz = 0, peak = 0
  for (let i = 0; i < count; i++) {
    const j = i * 3
    const px = points[j], py = points[j + 1], pz = points[j + 2]
    const wx = m[0] * px + m[4] * py + m[8] * pz + m[12]
    const wy = m[1] * px + m[5] * py + m[9] * pz + m[13]
    const wz = m[2] * px + m[6] * py + m[10] * pz + m[14]
    const nx = normals[j], ny = normals[j + 1], nz = normals[j + 2]
    let ox = m[0] * nx + m[4] * ny + m[8] * nz
    let oy = m[1] * nx + m[5] * ny + m[9] * nz
    let oz = m[2] * nx + m[6] * ny + m[10] * nz
    const nl = Math.hypot(ox, oy, oz) || 1
    ox /= nl; oy /= nl; oz /= nl
    let vx = cx - wx, vy = cy - wy, vz = cz - wz
    const vl = Math.hypot(vx, vy, vz) || 1
    vx /= vl; vy /= vl; vz /= vl
    const facing = ox * vx + oy * vy + oz * vz
    if (facing < 0.14) continue
    let hx = vx + light.x, hy = vy + light.y, hz = vz + light.z
    const hl = Math.hypot(hx, hy, hz) || 1
    hx /= hl; hy /= hl; hz /= hl
    const spec = Math.max(0, ox * hx + oy * hy + oz * hz) ** SHININESS
    const weight = spec * smooth(clamp((facing - 0.14) / 0.2))
    sum += weight; sx += wx * weight; sy += wy * weight; sz += wz * weight
    peak = Math.max(peak, weight)
  }
  if (sum > 1e-5) out.point.set(sx / sum, sy / sum, sz / sum)
  out.peak = peak
}

/** Throws when WebGL isn't available, so the page can fall back to its stills. */
export async function createCaseScene(canvas, { phone = false } = {}) {
  const { renderer, scene, camera } = createStage(canvas, { alpha: true, daylight: true })
  renderer.setClearColor(0x000000, 0)
  renderer.autoClear = false
  camera.fov = FOV
  camera.position.set(0, 0, DISTANCE)

  const mats = materials()
  mats.plastic.color.set(0xfbfaf7)
  mats.gloss.color.set(0xfcfbf8)
  mats.inner.color.set(0xeeedea)
  mats.plastic.clearcoatRoughness = 0.08
  mats.gloss.clearcoatRoughness = 0.1
  const model = createCase(await loadBudGeometry(), mats)
  const { buds, shells, opening } = model.userData

  // The case and the earbuds turn together but part ways once the earbuds lift out.
  const rig = new THREE.Group()
  const caseTurn = new THREE.Group()
  const budTurn = new THREE.Group()
  model.remove(buds)
  caseTurn.add(model)
  budTurn.add(buds)
  rig.add(caseTurn, budTurn)
  scene.add(rig)

  const docks = buds.children.map((dock) => ({
    dock, side: Math.sign(dock.position.x), position: dock.position.clone(), rotation: dock.rotation.clone(),
  }))

  const key = new THREE.DirectionalLight(0xffffff, 1.15)
  key.position.copy(KEY).multiplyScalar(300)
  const front = new THREE.DirectionalLight(0xfff8f2, 0.7)
  front.position.copy(FRONT).multiplyScalar(300)
  const glowA = new THREE.PointLight(0xff3d9a, 0, 0, 2)
  const glowB = new THREE.PointLight(0x27d3ff, 0, 0, 2)
  glowA.position.set(-13, 15, 2)
  glowB.position.set(13, 15, 2)
  caseTurn.add(glowA, glowB)
  scene.add(key, front)

  const divisor = phone ? 8 : 6
  const target = () => new THREE.WebGLRenderTarget(8, 8, { depthBuffer: false, type: THREE.UnsignedByteType })
  const silhouette = target(), scratch = target(), tight = target(), wide = target()
  const black = new THREE.MeshBasicMaterial({ color: 0x000000, side: THREE.DoubleSide })

  const blur = overlay({ tMap: { value: null }, uStep: { value: new THREE.Vector2() } }, blurShader)
  blur.transparent = false
  const blurPass = fullscreen(blur)

  const shadow = overlay({
    tTight: { value: tight.texture }, tWide: { value: wide.texture },
    uGround: { value: 0 }, uWall: { value: 0 }, uAura: { value: 0 }, uAspect: { value: 1 }, uTime: { value: 0 },
    uCase: { value: new THREE.Vector3(0.5, 0.5, 0.25) },
  }, shadowShader)
  const shadowPass = fullscreen(shadow)

  const flare = overlay({
    uFlares: { value: [new THREE.Vector4(), new THREE.Vector4(), new THREE.Vector4()] },
    uAspect: { value: 1 }, uPixel: { value: 0.002 }, uTime: { value: 0 },
  }, flareShader)
  flare.blending = THREE.NormalBlending
  const flarePass = fullscreen(flare)

  const overlayCamera = new THREE.Camera()
  const sampled = [
    sampleShell(shells[0], (y) => y < opening.y - 0.05),
    sampleShell(shells[1], (y) => y > opening.y + 0.05),
  ]
  const budShell = docks[0].dock.children[0].children[0]
  // The lid and the case catch light with the lid shut; once open, the earbuds' domes always do.
  const flares = [
    { shell: sampled[1], light: KEY, gain: () => (1 - pose.away) * (1 - smooth(clamp(pose.lid * 3))) },
    { shell: sampleShell(budShell, () => true), light: KEY, gain: () => smooth(clamp(pose.lid * 1.6 - 0.3)) },
  ].map((item) => ({ ...item, point: new THREE.Vector3(), peak: 0, shown: new THREE.Vector3(), level: 0, ready: false }))

  const pose = { x: 0, y: 0, s: 0.5, rx: 0, ry: 0, rz: 0, lid: 1, buds: 0, away: 0, led: 0, cavity: 0, ground: 0, wall: 0, aura: 0, flare: 0 }
  let width = 0, height = 0, cleared = false
  const projected = new THREE.Vector3()

  const resize = () => {
    const w = canvas.clientWidth, h = canvas.clientHeight
    if (!w || !h) return
    width = w
    height = h
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, phone ? 1.75 : 2))
    renderer.setSize(w, h, false)
    camera.aspect = w / h
    camera.updateProjectionMatrix()
    const tw = Math.max(8, Math.round(w / divisor)), th = Math.max(8, Math.round(h / divisor))
    for (const t of [silhouette, scratch, tight, wide]) t.setSize(tw, th)
    flare.uniforms.uAspect.value = camera.aspect
    shadow.uniforms.uAspect.value = camera.aspect
    flare.uniforms.uPixel.value = 2 / h
  }

  const setPose = (next) => {
    for (const name of Object.keys(pose)) pose[name] = number(next[name], pose[name])
    const scale = (pose.s * VIEW_HEIGHT) / CASE_HEIGHT
    const halfHeight = VIEW_HEIGHT / 2
    rig.position.set(pose.x * halfHeight * camera.aspect, pose.y * halfHeight, 0)
    rig.scale.setScalar(Math.max(scale, 1e-4))
    caseTurn.rotation.set(pose.rx, pose.ry, pose.rz)
    budTurn.rotation.set(pose.rx * (1 - pose.buds), pose.ry * (1 - pose.buds), pose.rz * (1 - pose.buds))

    const away = smooth(clamp(pose.away))
    caseTurn.position.y = (-away * VIEW_HEIGHT * 1.15) / Math.max(scale, 1e-4)
    model.visible = away < 0.999

    model.userData.setLid(clamp(pose.lid))
    model.userData.setLed(clamp(pose.led))

    // Lifted out and spread to either side, stems down, speakers turned to the viewer.
    const out = smooth(clamp(pose.buds))
    for (const { dock, side, position, rotation } of docks) {
      dock.position.set(
        lerp(position.x, side * 21, out),
        lerp(position.y, 11, out),
        lerp(position.z, 0, out),
      )
      dock.rotation.set(lerp(rotation.x, 0.08, out), lerp(rotation.y, -side * 0.42, out), lerp(rotation.z, -side * 0.12, out))
    }

    const glow = clamp(pose.cavity) * clamp(pose.lid * 2) * 950 * scale * scale
    glowA.intensity = glow
    glowB.intensity = glow

    const uv = shadow.uniforms.uCase.value
    uv.set((pose.x + 1) / 2, (pose.y + 1) / 2, pose.s / 2)
    shadow.uniforms.uGround.value = clamp(pose.ground) * (1 - away)
    shadow.uniforms.uWall.value = clamp(pose.wall)
    shadow.uniforms.uAura.value = clamp(pose.aura)
  }

  const blurInto = (source, destination, x, y) => {
    blur.uniforms.tMap.value = source.texture
    blur.uniforms.uStep.value.set(x / source.width, y / source.height)
    renderer.setRenderTarget(destination)
    renderer.clear()
    renderer.render(blurPass.scene, overlayCamera)
  }

  const renderShadows = () => {
    scene.overrideMaterial = black
    renderer.setRenderTarget(silhouette)
    renderer.clear()
    renderer.render(scene, camera)
    scene.overrideMaterial = null
    blurInto(silhouette, scratch, 0.8, 0)
    blurInto(scratch, tight, 0, 0.8)
    blurInto(tight, scratch, 2.6, 0)
    blurInto(scratch, wide, 0, 2.6)
    renderer.setRenderTarget(null)
  }

  const updateFlares = (delta) => {
    const size = clamp(pose.s * 2.1, 0.4, 1.3)
    const follow = 1 - Math.exp(-delta * 24)
    flares.forEach((item, i) => {
      findHighlight(item.shell, item.light, camera, item)
      const level = smooth(clamp((item.peak - 0.03) / 0.26)) * clamp(item.gain()) * clamp(pose.flare)
      if (!item.ready) { item.shown.copy(item.point); item.ready = true }
      item.shown.lerp(item.point, follow)
      item.level += (level - item.level) * (1 - Math.exp(-delta * 12))
      projected.copy(item.shown).project(camera)
      const value = flare.uniforms.uFlares.value[i]
      value.set(projected.x, projected.y, Number.isFinite(item.level) ? item.level : 0, size)
      if (!Number.isFinite(projected.x) || !Number.isFinite(projected.y)) value.set(0, 0, 0, size)
    })
  }

  let lastTime = 0
  const render = (time = 0) => {
    if (!width || !height) return
    const onStage = pose.s > 0.001 && !(pose.away >= 0.999 && pose.buds <= 0.001)
    if (!onStage) {
      if (!cleared) { renderer.clear(); cleared = true }
      return
    }
    cleared = false
    const delta = clamp((time - lastTime) / 1000, 0, 0.1)
    lastTime = time
    scene.updateMatrixWorld(true)

    const shadows = pose.ground > 0.001 || pose.wall > 0.001 || pose.aura > 0.001
    shadow.uniforms.uTime.value = time / 1000
    if (shadows) renderShadows()
    renderer.clear()
    if (shadows) renderer.render(shadowPass.scene, overlayCamera)
    renderer.render(scene, camera)
    if (pose.flare > 0.001) {
      updateFlares(delta || 0.016)
      flare.uniforms.uTime.value = time / 1000
      renderer.render(flarePass.scene, overlayCamera)
    }
  }

  const project = () => {
    scene.updateMatrixWorld(true)
    projected.copy(opening).applyMatrix4(model.matrixWorld).project(camera)
    return { x: number(projected.x, 0), y: number(projected.y, 0) }
  }

  resize()
  return { resize, setPose, render, project }
}
