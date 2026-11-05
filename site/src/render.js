import * as THREE from 'three'
import { createBud, createCase, createStage, loadBudGeometry, materials } from './airpods.js'
import { NAME, TAGLINE } from './config.js'

// Renders the art used by the app and the README, from the same model as the site.
// Open /render.html?shot=<name>, or call window.saveAll() to write every shot.
const SHOTS = {
  case: { size: 512, view: 'case', pose: [0.14, -0.42, 0], distance: 158, lid: 0 },
  hero: { size: 1024, view: 'case', pose: [0.26, -0.42, 0], distance: 182, lid: 1 },
  'buds-pair': { size: 512, view: 'pair', pose: [0.04, 0, 0], distance: 118 },
  icon: { size: 1024, view: 'case', pose: [0.14, -0.42, 0], distance: 158, lid: 0, compose: iconTile },
  og: { size: 1024, view: 'case', pose: [0.26, -0.42, 0], distance: 182, lid: 1, compose: ogCard },
}

const canvas = document.getElementById('c')
const stage = createStage(canvas, { alpha: true })
const mats = materials()
const budGeometry = await loadBudGeometry('/')
const holder = new THREE.Group()
stage.scene.add(holder)
const caseModel = createCase(budGeometry, mats)
const pair = new THREE.Group()
for (const side of [1, -1]) {
  const bud = createBud(budGeometry, mats, side)
  bud.position.set(-side * 14, 6, 0)
  bud.rotation.set(0.04, side * 0.28, side * 0.1)
  pair.add(bud)
}

window.renderShot = (name) => {
  const shot = SHOTS[name]
  holder.clear()
  const model = shot.view === 'pair' ? pair : caseModel
  holder.add(model)
  model.rotation.set(...shot.pose)
  model.userData.setLid?.(shot.lid ?? 0)
  stage.renderer.setPixelRatio(1)
  stage.renderer.setSize(shot.size, shot.size, false)
  stage.camera.aspect = 1
  stage.camera.position.set(0, 0, shot.distance)
  stage.camera.updateProjectionMatrix()
  stage.renderer.setClearColor(0x000000, 0)
  stage.renderer.render(stage.scene, stage.camera)
}

// The link preview image for social sites.
function ogCard() {
  const card = document.createElement('canvas')
  card.width = 1200
  card.height = 630
  const ctx = card.getContext('2d')
  ctx.fillStyle = '#000'
  ctx.fillRect(0, 0, 1200, 630)
  ctx.drawImage(canvas, 610, 25, 580, 580)
  ctx.fillStyle = '#f5f5f7'
  ctx.font = '700 72px -apple-system, Helvetica, Arial'
  ctx.fillText('Your AirPods case', 70, 280)
  ctx.fillText('is a mouse.', 70, 360)
  ctx.fillStyle = '#86868b'
  ctx.font = '500 32px -apple-system, Helvetica, Arial'
  ctx.fillText('PodMouse for Mac', 70, 200)
  return card
}

// The app icon: the macOS rounded tile, with the case resting on it.
function iconTile() {
  const size = 1024, inset = 100
  const tile = document.createElement('canvas')
  tile.width = tile.height = size
  const ctx = tile.getContext('2d')
  const gradient = ctx.createLinearGradient(0, inset, 0, size - inset)
  gradient.addColorStop(0, '#2c2c30')
  gradient.addColorStop(1, '#0c0c0e')
  ctx.beginPath()
  ctx.roundRect(inset, inset, size - inset * 2, size - inset * 2, 185)
  ctx.fillStyle = gradient
  ctx.fill()
  ctx.drawImage(canvas, 112, 112, 800, 800)
  return tile
}

window.saveAll = async () => {
  for (const name of Object.keys(SHOTS)) {
    window.renderShot(name)
    const source = SHOTS[name].compose?.() ?? canvas
    const blob = await new Promise((resolve) => source.toBlob(resolve, 'image/png'))
    await fetch(`/__save?name=${name}`, { method: 'POST', body: blob })
  }
  return Object.keys(SHOTS)
}

// The website's stills, lit for a pale page. They get their own stage, so the art above keeps its look.
let daylight

function daylightStage() {
  if (daylight) return daylight
  const surface = document.createElement('canvas')
  const stage = createStage(surface, { alpha: true, daylight: true })
  // Same adjustments as the live scene in stage.js.
  const lit = materials()
  lit.plastic.color.set(0xfbfaf7)
  lit.gloss.color.set(0xfcfbf8)
  lit.inner.color.set(0xeeedea)
  lit.plastic.clearcoatRoughness = 0.08
  lit.gloss.clearcoatRoughness = 0.1
  const key = new THREE.DirectionalLight(0xffffff, 1.15)
  key.position.set(-0.45, 0.8, 0.55).multiplyScalar(300)
  const front = new THREE.DirectionalLight(0xfff8f2, 0.7)
  front.position.set(-0.3, 0.32, 0.9).multiplyScalar(300)
  stage.scene.add(key, front)
  const model = createCase(budGeometry, lit)
  model.userData.setLid(1)
  const buds = new THREE.Group()
  for (const side of [1, -1]) {
    const bud = createBud(budGeometry, lit, side)
    bud.position.set(-side * 14, 6, 0)
    bud.rotation.set(0.04, side * 0.28, side * 0.1)
    buds.add(bud)
  }
  stage.scene.add(model, buds)
  daylight = { ...stage, surface, model, buds }
  return daylight
}

/** Draws one frame and copies it straight away: this stage's buffer doesn't outlive the task. */
function daylightShot({ view, pose, distance, size = 1024 }) {
  const { renderer, scene, camera, surface, model, buds } = daylightStage()
  model.visible = view === 'case'
  buds.visible = view === 'pair'
  ;(view === 'case' ? model : buds).rotation.set(...pose)
  renderer.setPixelRatio(1)
  renderer.setSize(size, size, false)
  renderer.setClearColor(0x000000, 0)
  camera.aspect = 1
  camera.position.set(0, 0, distance)
  camera.updateProjectionMatrix()
  renderer.render(scene, camera)
  const still = document.createElement('canvas')
  still.width = still.height = size
  still.getContext('2d').drawImage(surface, 0, 0)
  return still
}

const FLOW = ['#27d3ff', '#2f5bff', '#8a4dff', '#ff3d9a', '#ff8a3c', '#ffd9b8', '#27d3ff']

// The link preview: the page's light as a still, drawn with 2D canvas gradients.
async function siteCard(still) {
  const font = new FontFace('Bricolage Grotesque', 'url(/fonts/bricolage-grotesque.woff2)', { weight: '200 800', stretch: '75% 100%' })
  document.fonts.add(await font.load())
  const card = document.createElement('canvas')
  card.width = 1200
  card.height = 630
  const ctx = card.getContext('2d')
  const base = ctx.createLinearGradient(0, 0, 0, 630)
  base.addColorStop(0, '#f7f7fa')
  base.addColorStop(1, '#eef0f5')
  ctx.fillStyle = base
  ctx.fillRect(0, 0, 1200, 630)

  const cx = 880, cy = 330
  const flow = ctx.createConicGradient(-0.6, cx, cy)
  FLOW.forEach((color, i) => flow.addColorStop(i / (FLOW.length - 1), color))
  const halo = (radius, width, blur, alpha) => {
    ctx.save()
    ctx.filter = `blur(${blur}px)`
    ctx.globalAlpha = alpha
    ctx.strokeStyle = flow
    ctx.lineWidth = width
    ctx.beginPath()
    ctx.ellipse(cx, cy, radius, radius * 0.94, 0, 0, Math.PI * 2)
    ctx.stroke()
    ctx.restore()
  }
  halo(232, 90, 56, 0.7)
  halo(236, 26, 16, 0.95)
  const core = ctx.createRadialGradient(cx, cy, 30, cx, cy, 226)
  core.addColorStop(0, '#fff')
  core.addColorStop(0.72, 'rgba(255, 255, 255, 0.92)')
  core.addColorStop(1, 'rgba(255, 255, 255, 0)')
  ctx.fillStyle = core
  ctx.fillRect(cx - 240, cy - 240, 480, 480)

  ctx.save()
  ctx.shadowColor = 'rgba(30, 36, 80, 0.28)'
  ctx.shadowBlur = 44
  ctx.shadowOffsetY = 26
  ctx.drawImage(still, 575, 25, 610, 610)
  ctx.restore()

  ctx.fillStyle = '#0d0f16'
  ctx.fontStretch = 'semi-condensed'
  ctx.letterSpacing = '-2px'
  ctx.font = '800 88px "Bricolage Grotesque"'
  const lines = []
  for (const word of TAGLINE.split(' ')) {
    const line = lines.at(-1)
    if (line && ctx.measureText(`${line} ${word}`).width <= 520) lines[lines.length - 1] = `${line} ${word}`
    else lines.push(word)
  }
  const bottom = 340 + (lines.length * 88) / 2
  lines.forEach((line, i) => ctx.fillText(line, 64, bottom - (lines.length - 1 - i) * 88))
  ctx.letterSpacing = '0px'
  ctx.fillStyle = '#4b5060'
  ctx.font = '600 30px "Bricolage Grotesque"'
  ctx.fillText(`${NAME} for Mac`, 66, 92)
  return card
}

async function saveSite(name, canvasToSave) {
  const blob = await new Promise((resolve) => canvasToSave.toBlob(resolve, 'image/png'))
  await fetch(`/__save?name=${name}&to=site`, { method: 'POST', body: blob })
}

// Writes into site/public, unlike saveAll, which writes the app's resources.
window.saveSiteArt = async () => {
  const hero = daylightShot({ view: 'case', pose: [0.26, -0.42, 0], distance: 182 })
  await saveSite('hero', hero)
  await saveSite('buds-pair', daylightShot({ view: 'pair', pose: [0.04, 0, 0], distance: 118, size: 768 }))
  await saveSite('og', await siteCard(hero))
  return ['hero', 'buds-pair', 'og']
}

// Writes the model for the Mac app. Layout, little-endian: u32 part count, f32 lid hinge xyz, then
// per part u32 node (0 body, 1 lid), u32 material, u32 vertices, u32 indices,
// f32 positions, f32 normals, u32 indices. Lengths stay in millimetres.
window.exportMesh = async () => {
  const names = Object.keys(mats)
  const lid = caseModel.userData.lid
  caseModel.rotation.set(0, 0, 0)
  caseModel.userData.setLid(0)
  caseModel.updateMatrixWorld(true)
  const lidInverse = lid.matrixWorld.clone().invert()
  const parts = []
  caseModel.traverse((object) => {
    if (!object.isMesh) return
    let inLid = false
    for (let p = object.parent; p; p = p.parent) if (p === lid) inLid = true
    const matrix = inLid ? lidInverse.clone().multiply(object.matrixWorld) : object.matrixWorld.clone()
    const geometry = object.geometry.index ? object.geometry : null
    const source = geometry ?? object.geometry
    const position = source.attributes.position, normal = source.attributes.normal
    const normalMatrix = new THREE.Matrix3().getNormalMatrix(matrix)
    const positions = new Float32Array(position.count * 3), normals = new Float32Array(position.count * 3)
    const v = new THREE.Vector3()
    for (let i = 0; i < position.count; i++) {
      v.fromBufferAttribute(position, i).applyMatrix4(matrix)
      positions.set([v.x, v.y, v.z], i * 3)
      v.fromBufferAttribute(normal, i).applyMatrix3(normalMatrix).normalize()
      normals.set([v.x, v.y, v.z], i * 3)
    }
    let indices = source.index ? Uint32Array.from(source.index.array) : Uint32Array.from({ length: position.count }, (_, i) => i)
    if (matrix.determinant() < 0) {
      indices = indices.slice()
      for (let i = 0; i < indices.length; i += 3) [indices[i + 1], indices[i + 2]] = [indices[i + 2], indices[i + 1]]
    }
    parts.push({ node: inLid ? 1 : 0, material: names.indexOf(names.find((n) => mats[n] === object.material)), positions, normals, indices })
  })
  const hinge = new THREE.Vector3().setFromMatrixPosition(lid.matrixWorld)
  const size = 16 + parts.reduce((sum, p) => sum + 16 + p.positions.byteLength * 2 + p.indices.byteLength, 0)
  const buffer = new ArrayBuffer(size), view = new DataView(buffer)
  let at = 0
  const u32 = (x) => { view.setUint32(at, x, true); at += 4 }
  const f32 = (x) => { view.setFloat32(at, x, true); at += 4 }
  u32(parts.length); f32(hinge.x); f32(hinge.y); f32(hinge.z)
  for (const p of parts) {
    u32(p.node); u32(p.material); u32(p.positions.length / 3); u32(p.indices.length)
    p.positions.forEach(f32); p.normals.forEach(f32); p.indices.forEach(u32)
  }
  await fetch('/__save?name=airpods&ext=mesh', { method: 'POST', body: buffer })
  return { parts: parts.length, bytes: size, materials: names, hinge: hinge.toArray() }
}

window.renderShot(new URLSearchParams(location.search).get('shot') ?? 'hero')
window.ready = true
