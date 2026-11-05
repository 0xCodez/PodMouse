import { createField } from './field.js'
import { clamp, ease, lerp, resolveKeys, sample } from './timeline.js'

const root = document.documentElement
const motion = root.classList.contains('motion')

// Headings come apart into words so they can rise one at a time.
document.querySelectorAll('[data-split]').forEach((heading) => {
  heading.setAttribute('aria-label', heading.textContent.trim().replace(/\s+/g, ' '))
  let index = 0
  const split = (node) => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === Node.ELEMENT_NODE) { split(child); continue }
      if (child.nodeType !== Node.TEXT_NODE || !child.textContent.trim()) continue
      const words = child.textContent.split(/(\s+)/).map((part) => {
        if (!part.trim()) return document.createTextNode(part)
        const word = document.createElement('span')
        word.className = 'word'
        word.setAttribute('aria-hidden', 'true')
        word.style.setProperty('--i', index++)
        word.textContent = part
        return word
      })
      child.replaceWith(...words)
    }
  }
  split(heading)
})

const seen = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue
    entry.target.classList.add('in')
    seen.unobserve(entry.target)
  }
}, { rootMargin: '0px 0px -12% 0px' })
document.querySelectorAll('[data-reveal], [data-split]').forEach((el) => seen.observe(el))

if (motion) start().catch(fallBack)

// No WebGL, or it failed: the flat layout is complete on its own.
function fallBack(error) {
  console.warn('Falling back to the flat page:', error)
  root.classList.remove('motion')
}

async function start() {
  const field = createField(document.getElementById('field'))
  if (!field) throw new Error('WebGL is unavailable')
  // Paint the light now: the canvas is black until its first draw, and three.js is still to come.
  field.resize()
  field.render({ time: 0, blob: [0, -0.16, 0], ring: 0 })
  const phone = matchMedia('(max-width: 760px)').matches
  // Three.js and the meshes load after the type is on screen.
  const { createCaseScene } = await import('./stage.js')
  const stage = await createCaseScene(document.getElementById('scene'), { phone })

  const chapters = [...document.querySelectorAll('[data-chapter]')]
  const beats = chapters.flatMap((chapter) => [...chapter.querySelectorAll('[data-in]')].map((el) => {
    const [a, b, c, d] = el.dataset.in.split(' ').map(Number)
    return { el, chapter: chapter.dataset.chapter, a, b, c, d, shown: -1 }
  }))
  const pointer = document.getElementById('pointer')
  const readout = document.getElementById('readout')
  const target = document.getElementById('target')
  const demo = document.getElementById('demo')
  const gestures = [...document.querySelectorAll('[data-gesture]')]
  const slot = document.getElementById('slot')

  let viewW = 0, viewH = 0, aspect = 1, narrow = false
  let layout = {}, keys = []

  const measure = () => {
    const w = innerWidth, h = innerHeight
    if (!w || !h) return
    viewW = w
    viewH = h
    aspect = w / h
    narrow = w <= 760
    layout = {}
    for (const chapter of chapters) {
      const rect = chapter.getBoundingClientRect()
      layout[chapter.dataset.chapter] = { top: rect.top + scrollY, height: rect.height }
    }
    keys = resolveKeys(layout, h)
    // The hero's case sits in a real gap in the headline, wherever that gap landed.
    if (slot) {
      const rect = slot.getBoundingClientRect()
      const first = keys[0]
      if (rect.width && first) {
        // Wide screens seat it on the slot's lower edge, with the open lid rising toward the
        // first line. Phones stack the slot under the type, so there it simply centres.
        const share = narrow ? clamp((rect.height / h) * 0.58, 0.14, 0.3) : clamp((rect.width / h) * 0.62, 0.16, 0.46)
        const anchor = narrow ? rect.top + rect.height / 2 : rect.bottom
        first.x = first.mx = ((rect.left + rect.width / 2) / w) * 2 - 1
        first.y = first.my = 1 - ((anchor + scrollY) / h) * 2 - (narrow ? 0 : share * 0.42)
        first.s = first.ms = share
        first.blob = [first.x, first.y + share * 0.3, first.blob[2]]
      }
    }
    field.resize()
    stage.resize()
  }
  new ResizeObserver(measure).observe(document.body)
  addEventListener('resize', measure)
  document.fonts?.ready.then(measure)
  measure()

  const local = (name, scroll) => {
    const chapter = layout[name]
    if (!chapter) return 0
    const range = chapter.height - viewH
    return range > 0 ? clamp((scroll - chapter.top) / range) : 0
  }

  let mouseX = 0, mouseY = 0
  addEventListener('pointermove', (e) => {
    if (!viewW || !viewH) return
    mouseX = (e.clientX / viewW) * 2 - 1
    mouseY = 1 - (e.clientY / viewH) * 2
  }, { passive: true })

  // Everything below accumulates from frame to frame, so a bad value must never get in.
  const safe = (value, fallback) => (Number.isFinite(value) ? value : fallback)
  let smoothY = scrollY, smoothMX = 0, smoothMY = 0
  const blob = { x: 0, y: -0.16, vx: 0, vy: 0 }
  let last = performance.now()
  let introStart = 0
  let pulse = [0, 0, 0, 0]
  let lastTap = -1

  const hitTarget = (now) => {
    if (!target) return null
    const rect = target.getBoundingClientRect()
    if (!rect.width || !viewW) return null
    const x = ((rect.left + rect.width / 2) / viewW) * 2 - 1
    const y = 1 - ((rect.top + rect.height / 2) / viewH) * 2
    return { x, y, now }
  }

  const frame = (now) => {
    requestAnimationFrame(frame)
    // A background tab can report no size at all. Wait for it rather than divide by it.
    if (!viewW || !viewH) { measure(); last = now; return }
    if (!keys.length) return
    const dt = clamp(safe((now - last) / 1000, 0.016), 0.001, 0.05)
    last = now
    if (!introStart) introStart = now
    const time = now / 1000

    const follow = (rate) => 1 - Math.exp(-rate * dt)
    smoothY = safe(smoothY + (scrollY - smoothY) * follow(9), scrollY)
    smoothMX = safe(smoothMX + (mouseX - smoothMX) * follow(4), 0)
    smoothMY = safe(smoothMY + (mouseY - smoothMY) * follow(4), 0)

    const k = sample(keys, smoothY, narrow)
    const aim = local('aim', smoothY)
    const moves = local('gestures', smoothY)

    // The lid opens on load, so the case is never seen closed in use.
    const intro = ease(clamp((now - introStart) / 1500))
    const rise = 1 - (1 - clamp((now - introStart) / 1100)) ** 3
    k.lid *= ease(clamp((now - introStart - 350) / 1300))
    k.y -= (1 - rise) * 0.7
    k.ring *= intro
    k.cavity *= intro

    // Aim: the pointer draws a slow figure through the viewport and the case follows it.
    const aiming = clamp((aim - 0.36) / 0.06) * (1 - clamp((aim - 0.96) / 0.04))
    let px = 0.28, py = 0.18
    if (aiming > 0) {
      const wander = clamp((aim - 0.36) / 0.34)
      const settle = ease(clamp((aim - 0.62) / 0.1))
      const hit = hitTarget(now)
      const sway = lerp(0.03, 0.012, settle)
      const wx = lerp(-0.25, 0.42, ease(wander)) + Math.sin(wander * 9) * 0.26 * (1 - settle) + Math.sin(time * 1.1) * sway
      const wy = 0.1 + Math.sin(wander * 6 + 0.6) * 0.42 * (1 - settle) + Math.cos(time * 0.9) * sway
      px = hit ? lerp(wx, hit.x, settle) : wx
      py = hit ? lerp(wy, hit.y, settle) : wy
      if (narrow) py = clamp(py, -0.1, 0.7)
      const sx = ((px + 1) / 2) * viewW, sy = ((1 - py) / 2) * viewH
      pointer.style.transform = `translate3d(${sx.toFixed(1)}px, ${sy.toFixed(1)}px, 0)`
      if (readout) {
        // Near the right edge the numbers swap to the pointer's left so they never clip.
        const side = sx > viewW - 170 ? sx - 130 : sx + 28
        readout.style.transform = `translate3d(${side.toFixed(1)}px, ${(sy + 30).toFixed(1)}px, 0)`
        readout.textContent = `x ${px.toFixed(2)}  y ${py.toFixed(2)}`
      }
      k.ry += px * 0.34
      k.rx -= py * 0.22
    }
    pointer.style.opacity = aiming
    if (readout) readout.style.opacity = aiming

    // Tap: every 2.4 s while the third beat is up, the case jolts and the edge answers.
    let joltY = 0, joltZ = 0
    const tapping = aim > 0.74 && aim < 0.98
    if (target) target.style.opacity = clamp((aim - 0.58) / 0.08) * (1 - clamp((aim - 0.97) / 0.03))
    if (tapping) {
      const cycle = (time % 2.4) / 2.4
      const tap = Math.floor(time / 2.4)
      if (cycle < 0.04 && tap !== lastTap) {
        lastTap = tap
        target?.classList.add('hit')
        setTimeout(() => target?.classList.remove('hit'), 260)
        pulse = [px, py, 0, 1]
      }
      const decay = Math.exp(-cycle * 26)
      joltY = -Math.sin(cycle * 70) * decay * 0.02
      joltZ = Math.sin(cycle * 70) * decay * 0.05
      k.edge += decay * 0.5
    }
    if (pulse[3] > 0.001) {
      pulse[2] += dt * 1.1
      pulse[3] *= Math.exp(-dt * 3.2)
    } else pulse[3] = 0

    // Gestures: the case acts out whichever one is in focus.
    const active = Math.min(2, Math.floor(moves * 3))
    const inGestures = smoothY >= (layout.gestures?.top ?? Infinity) - viewH * 0.3
      && smoothY <= (layout.gestures?.top ?? 0) + (layout.gestures?.height ?? 0) - viewH * 0.7
    gestures.forEach((el, i) => el.classList.toggle('on', i === active))
    if (demo && demo.dataset.state !== String(active)) demo.dataset.state = active
    if (inGestures) {
      const cycle = (time % 2.2) / 2.2
      if (active === 0) {
        const decay = Math.exp(-cycle * 22)
        joltY += -Math.sin(cycle * 60) * decay * 0.02
        k.rx += Math.sin(cycle * 60) * decay * 0.05
      } else {
        const swing = Math.sin(clamp(cycle / 0.42) * Math.PI) ** 2
        k.rz += (active === 1 ? -1 : 1) * swing * 0.7
      }
    }

    for (const beat of beats) {
      const p = local(beat.chapter, smoothY)
      const opacity = clamp((p - beat.a) / Math.max(beat.b - beat.a, 0.001)) * (beat.d > beat.c ? 1 - clamp((p - beat.c) / (beat.d - beat.c)) : 1)
      const eased = ease(opacity)
      const rounded = Math.round(eased * 500) / 500
      if (rounded !== beat.shown) {
        beat.shown = rounded
        beat.el.style.opacity = rounded
        beat.el.style.visibility = rounded ? 'visible' : 'hidden'
        const leaving = p > beat.c
        beat.el.style.transform = `translate3d(0, ${((leaving ? -1 : 1) * (1 - eased) * 42).toFixed(1)}px, 0)`
      }
    }

    // A slight lean toward the visitor's own pointer, the way the real case follows a wrist.
    k.ry += smoothMX * 0.16
    k.rx -= smoothMY * 0.08
    const float = Math.sin(time * 0.8) * 0.007

    stage.setPose({
      x: k.x, y: k.y + float + joltY, s: k.s * (1 + joltZ), rx: k.rx, ry: k.ry, rz: k.rz,
      lid: k.lid, buds: k.buds, away: k.away, led: k.led * (0.7 + Math.sin(time * 3.2) * 0.3),
      cavity: k.cavity * (0.85 + Math.sin(time * 1.3) * 0.15), ground: k.ground, wall: k.wall, flare: k.flare,
    })
    stage.render(now)

    // The blob is on a spring toward its key, so it lags, overshoots and stretches as it goes.
    const driftX = Math.sin(time * 0.31) * 0.05 + Math.sin(time * 0.17 + 1.3) * 0.03
    const driftY = Math.cos(time * 0.27) * 0.05
    // Phones centre the case, so the glow follows it instead of its desktop position.
    const hugging = narrow && k.s > 0.05 && Math.abs(k.y) < 1
    const goalX = (hugging ? k.x : k.blob[0]) + driftX + smoothMX * 0.14
    const goalY = (hugging ? k.y : k.blob[1]) + driftY + smoothMY * 0.14
    blob.vx = safe(blob.vx + (goalX - blob.x) * 26 * dt, 0) * Math.exp(-6.5 * dt)
    blob.vy = safe(blob.vy + (goalY - blob.y) * 26 * dt, 0) * Math.exp(-6.5 * dt)
    blob.x = safe(blob.x + blob.vx * dt, goalX)
    blob.y = safe(blob.y + blob.vy * dt, goalY)

    const tip = k.beam > 0.01 ? stage.project() : { x: 0, y: 0 }
    field.render({
      time,
      // The radius is a share of the height, which on a phone would overflow the width.
      blob: [blob.x, blob.y, k.blob[2] * clamp(aspect * 0.62)],
      stretch: [blob.vx, blob.vy],
      ring: k.ring, edge: k.edge, wash: k.wash,
      beamA: [tip.x, tip.y], beamB: [px, py], beam: k.beam * aiming,
      pulse,
    })
  }
  requestAnimationFrame(frame)
}
