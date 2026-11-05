import * as THREE from 'three'
import { createBud, createCase, createStage, loadBudGeometry, materials } from './airpods.js'

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
