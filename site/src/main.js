import * as THREE from 'three'
import { createCase, createStage, loadBudGeometry, materials } from './airpods.js'
import { DOWNLOAD_URL, REPO_URL } from './config.js'

document.querySelectorAll('[data-download]').forEach((a) => { a.href = DOWNLOAD_URL })
document.querySelectorAll('[data-repo]').forEach((a) => { a.href = REPO_URL })

const canvas = document.getElementById('scene')
const story = document.getElementById('story')
const notch = document.getElementById('notch')
const screenEl = document.getElementById('screen')
const pointerEl = document.getElementById('pointer')
const notchTitle = document.getElementById('notch-title')
const notchText = document.getElementById('notch-text')
const dots = [...document.querySelectorAll('.notch-dots i')]
const targets = [...document.querySelectorAll('.target')]
const captions = [...document.querySelectorAll('.caption')].map((el) => ({
  el, from: Number(el.dataset.from), to: Number(el.dataset.to),
}))

const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x))
const ease = (x) => x * x * (3 - 2 * x)
const lerp = (a, b, t) => a + (b - a) * t
const span = (p, a, b) => ease(clamp((p - a) / (b - a)))

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches

// The case's path through the story. Values are read by progress and eased between stops.
const KEYS = [
  { p: 0.0, x: 0, y: -40, z: -26, rx: 0.12, ry: -0.42, rz: 0, lid: 0 },
  { p: 0.16, x: 0, y: -36, z: -22, rx: 0.14, ry: -0.2, rz: 0, lid: 0 },
  { p: 0.32, x: 26, y: -4, z: 34, rx: 0.42, ry: -0.5, rz: 0, lid: 1 },
  { p: 0.44, x: 26, y: -4, z: 38, rx: 0.42, ry: -0.22, rz: 0, lid: 1 },
  { p: 0.54, x: -24, y: -4, z: 26, rx: 0.2, ry: 0.42, rz: 0, lid: 1 },
  { p: 0.7, x: -24, y: -4, z: 26, rx: 0.2, ry: 0.1, rz: 0, lid: 1 },
  { p: 0.8, x: -34, y: -29, z: -30, rx: 0.26, ry: 0.32, rz: 0, lid: 1 },
  { p: 1.0, x: -34, y: -29, z: -30, rx: 0.26, ry: 0.32, rz: 0, lid: 1 },
]

function pose(p) {
  const i = Math.max(0, KEYS.findIndex((k) => k.p > p) - 1)
  const a = KEYS[i], b = KEYS[Math.min(i + 1, KEYS.length - 1)]
  const t = b === a ? 0 : ease(clamp((p - a.p) / (b.p - a.p)))
  return Object.fromEntries(Object.keys(a).map((key) => [key, lerp(a[key], b[key], t)]))
}

const CALIBRATION = [
  ['Hold still', 'Lid open, aimed at the screen.'],
  ['Left and right', 'Smoothly, three times.'],
  ['Up and down', 'Smoothly, three times.'],
]

function updateNotch(p) {
  const local = clamp((p - 0.5) / 0.18)
  notch.classList.toggle('on', p > 0.48 && p < 0.72)
  const step = Math.min(2, Math.floor(local * 3))
  notchTitle.textContent = CALIBRATION[step][0]
  notchText.textContent = CALIBRATION[step][1]
  dots.forEach((dot, i) => dot.style.setProperty('--fill', clamp(local * 3 - i)))
  return { step, stepProgress: clamp(local * 3 - step) }
}

// In the last act the pointer visits each target in turn, and the case follows it.
const STOPS = [
  { x: 0.2, y: 0.28 },
  { x: 0.73, y: 0.38 },
  { x: 0.49, y: 0.74 },
  { x: 0.2, y: 0.28 },
]

function updatePointer(p, time) {
  const active = p > 0.76
  screenEl.classList.toggle('on', active)
  if (!active) return { aimX: 0, aimY: 0 }
  const body = screenEl.querySelector('.screen-body').getBoundingClientRect()
  const cycle = ((time * 0.00022) % 1) * (STOPS.length - 1)
  const index = Math.floor(cycle)
  const t = ease(clamp((cycle - index) * 1.5))
  const a = STOPS[index], b = STOPS[index + 1]
  const x = lerp(a.x, b.x, t), y = lerp(a.y, b.y, t)
  pointerEl.style.transform = `translate(${x * body.width}px, ${y * body.height}px)`
  const dwelling = (cycle - index) > 0.72
  targets.forEach((target, i) => target.classList.toggle('hot', dwelling && (index + 1) % 3 === i))
  return { aimX: (x - 0.5) * 2, aimY: (y - 0.5) * 2 }
}

async function start() {
  const { renderer, scene, camera } = createStage(canvas)
  renderer.setClearAlpha(0)
  renderer.setClearColor(0x000000, 0)
  const mats = materials()
  const budGeometry = await loadBudGeometry()
  const model = createCase(budGeometry, mats)
  const holder = new THREE.Group()
  holder.add(model)
  scene.add(holder)

  // Floor shadow: a soft blob that keeps the case grounded on the black background.
  const glow = document.createElement('canvas')
  glow.width = glow.height = 256
  const ctx = glow.getContext('2d')
  const gradient = ctx.createRadialGradient(128, 128, 4, 128, 128, 128)
  gradient.addColorStop(0, 'rgba(255,255,255,0.22)')
  gradient.addColorStop(1, 'rgba(255,255,255,0)')
  ctx.fillStyle = gradient
  ctx.fillRect(0, 0, 256, 256)
  const floor = new THREE.Mesh(
    new THREE.PlaneGeometry(120, 44),
    new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(glow), transparent: true, depthWrite: false }),
  )
  floor.rotation.x = -Math.PI / 2
  floor.position.y = -34
  holder.add(floor)

  const resize = () => {
    const { clientWidth: w, clientHeight: h } = canvas
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
    renderer.setSize(w, h, false)
    camera.aspect = w / h
    // Keep the case framed on narrow windows: pull back as the view narrows.
    camera.position.set(0, 0, 235 * Math.max(1, 1.1 / camera.aspect))
    camera.updateProjectionMatrix()
  }
  addEventListener('resize', resize)
  resize()

  let mouseX = 0, mouseY = 0, smoothX = 0, smoothY = 0
  addEventListener('pointermove', (e) => {
    mouseX = (e.clientX / innerWidth - 0.5) * 2
    mouseY = (e.clientY / innerHeight - 0.5) * 2
  })

  // A tab opened in the background has no height yet, and this must not divide by zero:
  // smoothP accumulates, so a single NaN would stop the scene for good.
  const scrollProgress = () => {
    const range = story.offsetHeight - innerHeight
    return range > 0 ? clamp(-story.getBoundingClientRect().top / range) : 0
  }
  let smoothP = scrollProgress()

  const frame = (time) => {
    requestAnimationFrame(frame)
    const rect = story.getBoundingClientRect()
    if (rect.bottom < 0) return

    const target = scrollProgress()
    smoothP += (target - smoothP) * (reducedMotion ? 1 : 0.14)
    const p = smoothP
    captions.forEach((c) => c.el.classList.toggle('on', target >= c.from && target <= c.to))

    const k = pose(p)
    const narrow = camera.aspect < 1
    const { step, stepProgress } = updateNotch(p)
    const { aimX, aimY } = updatePointer(p, reducedMotion ? 0 : time)

    smoothX += (mouseX - smoothX) * 0.06
    smoothY += (mouseY - smoothY) * 0.06
    const float = reducedMotion ? 0 : Math.sin(time * 0.0009) * 0.9

    // During setup the case acts out each step; while pointing it aims with the pointer.
    const inSetup = span(p, 0.5, 0.54) * (1 - span(p, 0.68, 0.72))
    const turn = (step === 1 ? stepProgress : step > 1 ? 1 - (stepProgress * 0.4) : 0) * 0.5 * inSetup
    const tilt = (step === 2 ? stepProgress : 0) * 0.42 * inSetup
    const aiming = span(p, 0.78, 0.84)

    holder.position.set(narrow ? 0 : k.x, (narrow ? k.y * 0.75 : k.y) + float, k.z)
    model.rotation.set(
      k.rx + smoothY * 0.05 - tilt + aimY * 0.2 * aiming,
      k.ry + smoothX * 0.1 + turn + aimX * 0.42 * aiming,
      k.rz,
    )
    floor.material.opacity = 1 - span(p, 0.2, 0.3)
    model.userData.setLid(k.lid)
    model.userData.setLed(inSetup > 0.5 || aiming > 0.5 ? 0.6 + Math.sin(time * 0.004) * 0.3 : 0)
    renderer.render(scene, camera)
  }
  requestAnimationFrame(frame)
}

start().catch((error) => {
  console.error(error)
  canvas.hidden = true
  document.querySelector('.fallback').hidden = false
  captions[0].el.classList.add('on')
})
