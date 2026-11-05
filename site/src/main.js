import { createField } from './field.js'
import { clamp, ease, lerp, resolveKeys, sample } from './timeline.js'

const root = document.documentElement
const motion = root.classList.contains('motion')

// Headings come apart into words so they can rise one at a time.
document.querySelectorAll('[data-split]').forEach((heading) => {
  heading.setAttribute('aria-label', heading.textContent.trim().replace(/\s+/g, ' '))
  let index = 0
  const words = heading.textContent.split(/(\s+)/).map((part) => {
    if (!part.trim()) return document.createTextNode(part)
    const word = document.createElement('span')
    word.className = 'word'
    word.setAttribute('aria-hidden', 'true')
    word.style.setProperty('--i', index++)
    word.textContent = part
    return word
  })
  heading.replaceChildren(...words)
})

// The big lines go further: each letter rises out of its own word's mask.
if (motion) document.querySelectorAll('[data-chars]').forEach((line) => {
  if (!line.hasAttribute('aria-hidden')) line.setAttribute('aria-label', line.textContent.trim())
  let index = 0
  const parts = line.textContent.trim().split(/(\s+)/).map((part) => {
    if (!part.trim()) return document.createTextNode(' ')
    const word = document.createElement('span')
    word.className = 'mask'
    word.setAttribute('aria-hidden', 'true')
    for (const letter of part) {
      const span = document.createElement('span')
      span.className = 'ch'
      span.style.setProperty('--i', index++)
      span.textContent = letter
      word.append(span)
    }
    return word
  })
  line.replaceChildren(...parts)
})

const seen = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue
    entry.target.classList.add('in')
    seen.unobserve(entry.target)
  }
}, { rootMargin: '0px 0px -10% 0px' })
document.querySelectorAll('[data-reveal], [data-split], [data-chars]').forEach((el) => {
  if (!el.closest('.beat')) seen.observe(el)
})

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
  field.render({ time: 0, blob: [0, 0, 0] })
  const phone = matchMedia('(max-width: 760px)').matches
  const { createCaseScene } = await import('./stage.js')
  const stage = await createCaseScene(document.getElementById('scene'), { phone })

  const chapters = [...document.querySelectorAll('[data-chapter]')]
  const beats = chapters.flatMap((chapter) => [...chapter.querySelectorAll('[data-in]')].map((el) => {
    const [a, b, c, d] = el.dataset.in.split(' ').map(Number)
    return { el, chapter: chapter.dataset.chapter, a, b, c, d, on: false, past: false }
  }))
  const pointer = document.getElementById('pointer')
  const readout = document.getElementById('readout')
  const target = document.getElementById('target')
  const gestures = [...document.querySelectorAll('[data-gesture]')]
  const beam = document.getElementById('beam')
  const beamInk = document.getElementById('beam-ink')
  const ripple = document.getElementById('ripple')
  const cursor = document.getElementById('cursor')
  const degrees = document.getElementById('degrees')
  const finaleButton = document.querySelector('.download .cta')

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
    beam.parentNode.setAttribute('viewBox', `0 0 ${w} ${h}`)
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

  // A real mouse gets a hairline ring and a beam from the case. Touch screens get neither.
  const fine = matchMedia('(hover: hover) and (pointer: fine)').matches
  let mouseX = 0, mouseY = 0, pagePX = 0, pagePY = 0, activity = 0, hovering = false
  addEventListener('pointermove', (e) => {
    if (!viewW || !viewH) return
    pagePX = e.clientX
    pagePY = e.clientY
    mouseX = (e.clientX / viewW) * 2 - 1
    mouseY = 1 - (e.clientY / viewH) * 2
    activity = 1
    hovering = Boolean(e.target.closest?.('a'))
  }, { passive: true })

  // Buttons lean toward the pointer before it arrives.
  document.querySelectorAll('.cta, .nav-cta').forEach((el) => {
    el.addEventListener('pointermove', (e) => {
      const rect = el.getBoundingClientRect()
      const dx = e.clientX - rect.left - rect.width / 2
      const dy = e.clientY - rect.top - rect.height / 2
      el.style.transform = `translate(${(dx * 0.2).toFixed(1)}px, ${(dy * 0.28).toFixed(1)}px)`
    })
    el.addEventListener('pointerleave', () => { el.style.transform = '' })
  })

  // Everything below accumulates from frame to frame, so a bad value must never get in.
  const safe = (value, fallback) => (Number.isFinite(value) ? value : fallback)
  let smoothY = scrollY, smoothMX = 0, smoothMY = 0, ringX = 0, ringY = 0, ringR = 13
  const blob = { x: 0, y: 0, vx: 0, vy: 0 }
  let last = performance.now()
  let introStart = 0
  let flash = 0, tapTime = -10, lastTap = -1
  let ripX = 0, ripY = 0, ripR = 0, ripA = 0
  let countStart = 0

  const tap = (x, y, time) => {
    flash = 1
    tapTime = time
    ripX = x
    ripY = y
    ripR = 4
    ripA = 1
  }
  addEventListener('pointerdown', (e) => tap(e.clientX, e.clientY, performance.now() / 1000), { passive: true })

  const count = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting) return
    countStart = performance.now()
    count.disconnect()
  }, { threshold: 0.4 })
  count.observe(degrees)

  const centreOf = (el) => {
    const rect = el.getBoundingClientRect()
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, width: rect.width }
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
    smoothMX = safe(smoothMX + (mouseX - smoothMX) * follow(5), 0)
    smoothMY = safe(smoothMY + (mouseY - smoothMY) * follow(5), 0)
    activity *= Math.exp(-dt * 0.8)
    flash *= Math.exp(-dt * 4.5)

    const k = sample(keys, smoothY, narrow)
    const aim = local('aim', smoothY)
    const moves = local('gestures', smoothY)
    const heroness = 1 - clamp(smoothY / (viewH * 0.7))

    // The lid opens on load, so the case is never seen closed in use.
    const age = now - introStart
    const rise = 1 - (1 - clamp(age / 1200)) ** 4
    const lid = ease(clamp((age - 300) / 1300))
    k.y -= (1 - rise) * 0.5
    k.ry += (1 - rise) * 0.9

    // Aim: the pointer draws a slow figure through the viewport and the case follows it.
    const aiming = clamp((aim - 0.36) / 0.06) * (1 - clamp((aim - 0.96) / 0.04))
    let px = 0.3, py = 0.3
    if (aiming > 0) {
      const wander = clamp((aim - 0.36) / 0.34)
      const settle = ease(clamp((aim - 0.62) / 0.1))
      const sway = lerp(0.03, 0.008, settle)
      const wx = lerp(-0.05, 0.42, ease(wander)) + Math.sin(wander * 9) * 0.24 * (1 - settle) + Math.sin(time * 1.1) * sway
      const wy = 0.28 + Math.sin(wander * 6 + 0.6) * 0.34 * (1 - settle) + Math.cos(time * 0.9) * sway
      const hit = target ? centreOf(target) : null
      px = hit?.width ? lerp(wx, (hit.x / viewW) * 2 - 1, settle) : wx
      py = hit?.width ? lerp(wy, 1 - (hit.y / viewH) * 2, settle) : wy
      if (narrow) py = clamp(py, 0.12, 0.74)
      const sx = ((px + 1) / 2) * viewW, sy = ((1 - py) / 2) * viewH
      pointer.style.transform = `translate3d(${sx.toFixed(1)}px, ${sy.toFixed(1)}px, 0)`
      // Near the right edge the numbers swap to the pointer's left so they never clip.
      const side = sx > viewW - 170 ? sx - 130 : sx + 28
      readout.style.transform = `translate3d(${side.toFixed(1)}px, ${(sy + 30).toFixed(1)}px, 0)`
      readout.textContent = `x ${px.toFixed(2)}  y ${py.toFixed(2)}`
      k.ry += px * 0.3
      k.rx -= py * 0.2
    }
    pointer.style.opacity = aiming
    readout.style.opacity = aiming
    target.style.opacity = clamp((aim - 0.58) / 0.08) * (1 - clamp((aim - 0.97) / 0.03))

    // Tap: every 2.4 s while the third beat is up.
    if (aim > 0.74 && aim < 0.98) {
      const cycle = Math.floor(time / 2.4)
      if (cycle !== lastTap && time % 2.4 < 0.2) {
        lastTap = cycle
        target.classList.add('hit')
        setTimeout(() => target.classList.remove('hit'), 260)
        tap(((px + 1) / 2) * viewW, ((1 - py) / 2) * viewH, time)
      }
    }
    // Any tap, the page's own or the visitor's real click, kicks the case the same way.
    const since = time - tapTime
    const kick = since >= 0 && since < 1 ? Math.sin(since * 34) * Math.exp(-since * 9) : 0
    k.rx += kick * 0.05

    // Gestures: the case acts out whichever one is in focus.
    const active = Math.min(2, Math.floor(moves * 3))
    const span = layout.gestures
    const inGestures = span && smoothY >= span.top - viewH * 0.3 && smoothY <= span.top + span.height - viewH * 0.7
    gestures.forEach((el, i) => el.classList.toggle('on', i === active))
    if (inGestures) {
      const cycle = (time % 2.2) / 2.2
      if (active === 0) {
        const decay = Math.exp(-cycle * 22)
        k.rx += Math.sin(cycle * 60) * decay * 0.05
      } else {
        const swing = Math.sin(clamp(cycle / 0.42) * Math.PI) ** 2
        k.rz += (active === 1 ? -1 : 1) * swing * 0.7
      }
    }

    for (const beat of beats) {
      const place = layout[beat.chapter]
      const p = local(beat.chapter, smoothY)
      const entered = beat.a > 0 ? p >= beat.a : place && smoothY >= place.top - viewH * 0.45
      const past = p > beat.c
      const on = Boolean(entered) && !past
      if (on !== beat.on) { beat.on = on; beat.el.classList.toggle('on', on) }
      if (past !== beat.past) { beat.past = past; beat.el.classList.toggle('past', past) }
    }

    // In the hero the case tracks the visitor's pointer properly; later it only leans.
    k.ry += smoothMX * lerp(0.1, 0.55, heroness)
    k.rx -= smoothMY * lerp(0.05, 0.3, heroness)

    stage.setPose({
      x: k.x, y: k.y + Math.sin(time * 0.8) * 0.006, s: k.s, rx: k.rx, ry: k.ry, rz: k.rz,
      lid, buds: k.buds, away: k.away, led: 0.5 + Math.sin(time * 3.2) * 0.25,
      cavity: 0.3, ground: k.ground, wall: k.wall, flare: 0.42,
      aura: (k.aura * 0.5 + flash * 0.5) * rise,
    })
    stage.render(now)

    // The pool of light springs after the case and the pointer, so it lags and stretches.
    const shown = Math.abs(k.y) < 1 && k.s > 0.05
    const goalX = (shown ? k.x : 0) + smoothMX * 0.16
    const goalY = (shown ? k.y : 0) + smoothMY * 0.16
    blob.vx = safe(blob.vx + (goalX - blob.x) * 26 * dt, 0) * Math.exp(-6.5 * dt)
    blob.vy = safe(blob.vy + (goalY - blob.y) * 26 * dt, 0) * Math.exp(-6.5 * dt)
    blob.x = safe(blob.x + blob.vx * dt, goalX)
    blob.y = safe(blob.y + blob.vy * dt, goalY)
    field.render({
      time,
      // The radius is a share of the height, which on a phone would overflow the width.
      blob: [blob.x, blob.y, 0.5 * clamp(aspect * 0.62)],
      stretch: [blob.vx, blob.vy],
      edge: flash * 0.75,
    })

    // One hairline: from the case to the pointer, the page's own or the visitor's, or the button.
    const finale = clamp((smoothY - (layout.download?.top ?? Infinity) + viewH * 0.1) / (viewH * 0.1))
    const heroBeam = fine ? heroness * activity : 0
    let endX = pagePX, endY = pagePY, strength = heroBeam
    if (aiming > heroBeam) {
      endX = ((px + 1) / 2) * viewW
      endY = ((1 - py) / 2) * viewH
      strength = aiming * k.beam
    } else if (finale > heroBeam && finaleButton) {
      const button = centreOf(finaleButton)
      endX = button.x
      endY = button.y
      strength = finale * k.beam
    }
    if (strength > 0.01) {
      const tip = stage.project()
      const startX = ((tip.x + 1) / 2) * viewW, startY = ((1 - tip.y) / 2) * viewH
      for (const node of [beam, beamInk]) {
        node.setAttribute('x1', startX.toFixed(1))
        node.setAttribute('y1', startY.toFixed(1))
        node.setAttribute('x2', endX.toFixed(1))
        node.setAttribute('y2', endY.toFixed(1))
      }
    }
    beam.style.opacity = strength > 0.01 ? strength : 0

    if (ripA > 0.004) {
      ripR += dt * (viewH * 0.5) * (0.4 + ripA)
      ripA *= Math.exp(-dt * 3.4)
      ripple.setAttribute('cx', ripX.toFixed(1))
      ripple.setAttribute('cy', ripY.toFixed(1))
      ripple.setAttribute('r', ripR.toFixed(1))
      ripple.style.opacity = ripA
    } else if (ripA) { ripA = 0; ripple.style.opacity = 0 }

    if (fine) {
      ringX = safe(ringX + (pagePX - ringX) * follow(16), pagePX)
      ringY = safe(ringY + (pagePY - ringY) * follow(16), pagePY)
      ringR += ((hovering ? 26 : 13) - ringR) * follow(12)
      cursor.setAttribute('cx', ringX.toFixed(1))
      cursor.setAttribute('cy', ringY.toFixed(1))
      cursor.setAttribute('r', ringR.toFixed(1))
      cursor.style.opacity = activity > 0.02 ? 1 : 0
    }

    if (countStart) {
      const t = clamp((now - countStart) / 1600)
      degrees.textContent = `${Math.round(ease(t) * 74)}°`
      if (t >= 1) countStart = 0
    }
  }
  requestAnimationFrame(frame)
}
