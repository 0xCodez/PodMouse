// The whole page is one camera move. Each key is pinned to a place in the document, not to a
// percentage of it, so section heights can differ between phones and desktops.
// `at` is [chapter, progress through its pin, extra viewport heights].
// x, y are viewport-relative with y up; s is the closed case's height as a share of the viewport.
// mx, my, ms replace x, y, s on narrow screens.
export const KEYS = [
  // The case is left alone in white space, with one line of type beside it.
  { at: ['hero', 0], x: 0.3, y: 0.1, s: 0.44, mx: 0, my: 0.04, ms: 0.25, rx: 0.42, ry: -0.46, rz: 0.06, beam: 0, ground: 1, wall: 0.4, aura: 0.7, buds: 0, away: 0 },
  { at: ['hero', 0, 0.7], x: 0.34, y: 0.12, s: 0.46, mx: 0, my: 0.1, ms: 0.26, rx: 0.7, ry: -0.2, rz: 0.04, beam: 0, ground: 0.2, wall: 0.5, aura: 0.7, buds: 0, away: 0 },
  // Open it: the case turns to show the cavity.
  { at: ['aim', 0.02], x: 0.32, y: 0.1, s: 0.5, mx: 0, my: 0.2, ms: 0.25, rx: 0.9, ry: 0.26, rz: -0.08, beam: 0, ground: 0, wall: 0.5, aura: 0.6, buds: 0, away: 0 },
  { at: ['aim', 0.3], x: 0.32, y: 0.08, s: 0.52, mx: 0, my: 0.2, ms: 0.26, rx: 0.8, ry: -0.3, rz: 0.06, beam: 0, ground: 0, wall: 0.5, aura: 0.6, buds: 0, away: 0 },
  // Aim it: the viewport becomes the screen, and the case points into it from the side.
  { at: ['aim', 0.42], x: -0.56, y: 0.04, s: 0.4, mx: 0, my: -0.1, ms: 0.2, rx: 0.34, ry: 0.72, rz: -0.34, beam: 1, ground: 0, wall: 0.4, aura: 0.5, buds: 0, away: 0 },
  { at: ['aim', 0.66], x: -0.56, y: 0.04, s: 0.4, mx: 0, my: -0.1, ms: 0.2, rx: 0.34, ry: 0.72, rz: -0.34, beam: 1, ground: 0, wall: 0.4, aura: 0.5, buds: 0, away: 0 },
  // Tap to click: everything stops so the tap reads.
  { at: ['aim', 0.76], x: -0.54, y: 0.02, s: 0.42, mx: 0, my: -0.1, ms: 0.2, rx: 0.3, ry: 0.5, rz: -0.2, beam: 0.7, ground: 0, wall: 0.4, aura: 0.5, buds: 0, away: 0 },
  { at: ['aim', 1], x: -0.54, y: 0.02, s: 0.42, mx: 0, my: -0.1, ms: 0.2, rx: 0.3, ry: 0.5, rz: -0.2, beam: 0.7, ground: 0, wall: 0.4, aura: 0.5, buds: 0, away: 0 },
  // Gestures: the case stands left and acts each one out.
  { at: ['gestures', 0], x: -0.46, y: -0.02, s: 0.46, mx: 0, my: 0.08, ms: 0.25, rx: 0.42, ry: 0.42, rz: 0, beam: 0, ground: 0, wall: 0.5, aura: 0.6, buds: 0, away: 0 },
  { at: ['gestures', 1], x: -0.46, y: -0.02, s: 0.46, mx: 0, my: 0.08, ms: 0.25, rx: 0.42, ry: 0.3, rz: 0, beam: 0, ground: 0, wall: 0.5, aura: 0.6, buds: 0, away: 0 },
  // Modes: first the case, then the earbuds rise and the case drops out of frame.
  { at: ['modes', 0.05], x: 0.34, y: 0.06, s: 0.46, mx: 0, my: 0.18, ms: 0.25, rx: 0.5, ry: -0.42, rz: 0.06, beam: 0, ground: 0, wall: 0.5, aura: 0.6, buds: 0, away: 0 },
  { at: ['modes', 0.42], x: 0.34, y: 0.06, s: 0.46, mx: 0, my: 0.18, ms: 0.25, rx: 0.5, ry: -0.3, rz: 0.06, beam: 0, ground: 0, wall: 0.5, aura: 0.6, buds: 0, away: 0 },
  { at: ['modes', 0.62], x: -0.42, y: 0.04, s: 0.46, mx: 0, my: 0.34, ms: 0.3, rx: 0.16, ry: 0.1, rz: 0, beam: 0, ground: 0, wall: 0.4, aura: 0.5, buds: 1, away: 1 },
  { at: ['modes', 1], x: -0.42, y: 0.04, s: 0.46, mx: 0, my: 0.34, ms: 0.3, rx: 0.16, ry: -0.16, rz: 0, beam: 0, ground: 0, wall: 0.4, aura: 0.5, buds: 1, away: 1 },
  // The reading sections have no 3D at all, so the page stops paying for it. A scale of zero
  // draws nothing, which also lets the case cross behind the page unseen to its last entrance.
  { at: ['fit', 0, -0.2], x: -0.9, y: 1.7, s: 0.46, mx: 0, my: 1.7, ms: 0.3, rx: 0.1, ry: -0.6, rz: 0, beam: 0, ground: 0, wall: 0, aura: 0, buds: 1, away: 1 },
  { at: ['fit', 0, 0.3], x: -0.9, y: 1.7, s: 0, mx: 0, my: 1.7, ms: 0, rx: 0.1, ry: -0.6, rz: 0, beam: 0, ground: 0, wall: 0, aura: 0, buds: 1, away: 1 },
  { at: ['privacy', 0], x: 0.46, y: -1.8, s: 0, mx: 0, my: -1.8, ms: 0, rx: 0.5, ry: -0.3, rz: 0, beam: 0, ground: 0, wall: 0, aura: 0, buds: 0, away: 0 },
  { at: ['specs', 0], x: 0.46, y: -1.8, s: 0, mx: 0, my: -1.8, ms: 0, rx: 0.5, ry: -0.3, rz: 0, beam: 0, ground: 0, wall: 0, aura: 0, buds: 0, away: 0 },
  // The last screen: the case takes aim at the button.
  { at: ['download', 0, -0.35], x: 0.46, y: -1.3, s: 0.34, mx: 0, my: -1.3, ms: 0.17, rx: 0.5, ry: -0.3, rz: 0, beam: 0, ground: 0, wall: 0.4, aura: 0.5, buds: 0, away: 0 },
  { at: ['download', 0], x: 0.46, y: 0.12, s: 0.4, mx: 0, my: 0.14, ms: 0.17, rx: 0.42, ry: 0.5, rz: -0.14, beam: 1, ground: 0.6, wall: 0.4, aura: 0.7, buds: 0, away: 0 },
  // The page keeps scrolling to the footer here, so the case leaves with it.
  { at: ['download', 0, 0.5], x: 0.46, y: 1.12, s: 0.4, mx: 0, my: 1.14, ms: 0.17, rx: 0.42, ry: 0.5, rz: -0.14, beam: 1, ground: 0.6, wall: 0.4, aura: 0.7, buds: 0, away: 0 },
]

const VALUES = ['rx', 'ry', 'rz', 'buds', 'away', 'ground', 'wall', 'aura', 'beam']

export const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x))
export const ease = (x) => x * x * (3 - 2 * x)
export const lerp = (a, b, t) => a + (b - a) * t

/** Turns each key's document position into a scroll offset. Later keys never sort before earlier ones. */
export function resolveKeys(layout, viewport) {
  let previous = -Infinity
  return KEYS.map((key) => {
    const [name, progress, extra = 0] = key.at
    const chapter = layout[name]
    const raw = chapter ? chapter.top + progress * Math.max(chapter.height - viewport, 0) + extra * viewport : previous
    previous = Math.max(previous, raw)
    return { ...key, y0: previous }
  })
}

/** The scene at a scroll offset, eased between neighbouring keys. */
export function sample(keys, scroll, narrow) {
  let i = 0
  while (i < keys.length - 2 && keys[i + 1].y0 <= scroll) i++
  const a = keys[i], b = keys[i + 1]
  const range = b.y0 - a.y0
  const t = range > 0 ? ease(clamp((scroll - a.y0) / range)) : 0
  const out = {
    x: lerp(narrow ? a.mx : a.x, narrow ? b.mx : b.x, t),
    y: lerp(narrow ? a.my : a.y, narrow ? b.my : b.y, t),
    s: lerp(narrow ? a.ms : a.s, narrow ? b.ms : b.s, t),
  }
  for (const key of VALUES) out[key] = lerp(a[key], b[key], t)
  return out
}
