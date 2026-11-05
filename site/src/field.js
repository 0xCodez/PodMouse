// The page's background. Each entry in BACKGROUNDS is one design, and all of them share the same
// inputs: time, a light that follows the pointer, a target to press or aim at, a click wave and
// the scroll position. `cap` is the buffer width: line work needs more pixels than soft colour.

const FALLBACK = {
  '--pearl': '#EFEEF4', '--pearl-2': '#F8F7FB', '--paper': '#FFFFFF', '--shade': '#BFC3DA',
  '--cobalt': '#2F5BFF', '--violet': '#8A4DFF', '--pink': '#FF3D9A', '--tangerine': '#FF8A3C', '--cyan': '#27D3FF',
}

const hex = (name) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  const match = /^#([0-9a-f]{6})$/i.exec(value) ?? /^#([0-9a-f]{6})$/i.exec(FALLBACK[name])
  return [0, 2, 4].map((i) => parseInt(match[1].slice(i, i + 2), 16) / 255)
}

const vec3 = ([r, g, b]) => `vec3(${r.toFixed(4)},${g.toFixed(4)},${b.toFixed(4)})`

export const BACKGROUNDS = {
  silk: { cap: 800, source: `
float cloth(vec2 p) {
  float t = uT * 0.05;
  vec2 q = p + vec2(0.0, uScroll);
  q = vec2(q.x * 0.82 + q.y * 0.57, q.y * 0.82 - q.x * 0.57);
  vec2 drift = vec2(noise(q * 0.42 + vec2(t, -t * 0.7)), noise(q * 0.42 + vec2(5.2 - t * 0.8, 1.3 + t)));
  q += drift * 1.3;
  float h = sin(q.x * 2.1 + noise(q * 0.3 + t * 0.6) * 3.0) * 0.62;
  h += sin(q.x * 4.1 + q.y * 0.7 + drift.y * 2.4) * 0.2;
  h += noise(q * vec2(2.4, 0.7) + t * 1.2) * 0.1;
  vec2 toDent = p / zoom - uDent.xy;
  h -= 0.5 * uDent.z * exp(-dot(toDent, toDent) * 5.0);
  if (uWave.w > 0.001) {
    float d = length(p / zoom - uWave.xy) - uWave.z;
    h += 0.34 * uWave.w * sin(d * 16.0) * exp(-d * d * 14.0);
  }
  return h;
}

vec3 background(vec2 p, float aspect) {
  vec2 sheet = p * zoom;
  float e = 0.014;
  float h = cloth(sheet);
  vec3 n = normalize(vec3((h - cloth(sheet + vec2(e, 0.0))) / e * 0.27, (h - cloth(sheet + vec2(0.0, e))) / e * 0.27, 1.0));
  vec3 l = normalize(vec3(uLight, 0.85));
  vec3 halfway = normalize(l + vec3(0.0, 0.0, 1.0));
  float facing = max(dot(n, halfway), 0.0);
  float lit = smoothstep(0.18, 0.96, dot(n, l) * 0.5 + 0.5);
  vec3 col = mix(SHADE, PAPER, lit);
  float slope = smoothstep(0.04, 0.42, length(n.xy));
  float phase = h * 0.13 + dot(n.xy, vec2(0.8, 0.5)) * 0.62 + uT * 0.012 + uScroll * 0.08;
  vec3 film = mix(flow(phase), vec3(1.0), 0.42);
  col = mix(col, film * mix(0.86, 1.0, lit), 0.4 * slope * (1.0 - uCalm * 0.42));
  return col + vec3(0.05) * pow(facing, 14.0) + vec3(0.14) * pow(facing, 120.0);
}
` },
  glass: { cap: 960, source: `
// Reeded glass: every flute bends the colour behind it sideways, so soft shapes break into ribs.
vec3 behind(vec2 q) {
  float t = uT * 0.07;
  vec3 col = vec3(0.955, 0.95, 0.975);
  vec2 a = q - vec2(sin(t) * 0.9 - 0.5, cos(t * 0.8) * 0.5 + 0.2);
  vec2 b = q - vec2(cos(t * 0.7) * 1.0 + 0.7, sin(t * 0.9) * 0.6 - 0.3);
  vec2 c = q - vec2(sin(t * 0.6 + 2.0) * 1.2, cos(t * 1.1 + 1.0) * 0.7);
  vec2 d = q - uDent.xy;
  col = mix(col, vec3(0.42, 0.56, 1.0), 0.8 * exp(-dot(a, a) * 1.3));
  col = mix(col, vec3(1.0, 0.62, 0.42), 0.8 * exp(-dot(b, b) * 1.5));
  col = mix(col, vec3(1.0, 0.5, 0.74), 0.7 * exp(-dot(c, c) * 2.0));
  return mix(col, vec3(0.64, 0.42, 1.0), 0.75 * uDent.z * exp(-dot(d, d) * 4.0));
}

vec3 background(vec2 p, float aspect) {
  float count = 11.0 * zoom;
  float u = p.x * count + uScroll * 6.0;
  float f = fract(u) - 0.5;
  float ripple = 0.0;
  if (uWave.w > 0.001) {
    float d = length(p - uWave.xy) - uWave.z;
    ripple = 0.08 * uWave.w * sin(d * 18.0) * exp(-d * d * 12.0);
  }
  vec2 q = p + vec2(f * 0.5 + ripple, uScroll * 0.6);
  vec3 col = behind(q);
  col *= 1.0 - 0.1 * smoothstep(0.1, 0.5, f) ;
  col += vec3(0.1) * smoothstep(-0.5, -0.2, f) * smoothstep(0.1, -0.2, f);
  col = mix(col, vec3(1.0), 0.3 * smoothstep(0.46, 0.5, abs(f)));
  return col;
}
` },
  sun: { cap: 800, source: `
// Late sun through a window on a plaster wall, with leaves moving outside.
float leaves(vec2 p) {
  float t = uT * 0.22;
  vec2 q = p * 2.1 + vec2(noise(p * 0.7 + t * 0.3), noise(p * 0.7 - t * 0.2 + 4.0)) * 0.9;
  float a = noise(q + vec2(t * 0.5, -t * 0.3));
  float b = noise(q * 2.3 - vec2(t * 0.4, t * 0.2) + 7.0);
  return smoothstep(0.02, 0.38, a + b * 0.45);
}

vec3 background(vec2 p, float aspect) {
  vec2 q = p * zoom + (uLight + vec2(0.42, -0.62)) * 0.14 + vec2(0.0, uScroll * 0.5);
  q = vec2(q.x * 0.9 + q.y * 0.44, q.y * 0.9 - q.x * 0.44);
  q.x += q.y * 0.28;

  // Four tall panes with soft edges, the frame between them throwing a shadow.
  float cols = smoothstep(0.02, 0.17, abs(fract(q.x * 0.62 + 0.13) - 0.5) * 2.0 - 0.08);
  float rows = smoothstep(0.02, 0.15, abs(fract(q.y * 0.42 + 0.3) - 0.5) * 2.0 - 0.05);
  float window = cols * rows * smoothstep(1.9, 1.1, abs(q.x + 0.25));
  float sun = window * (1.0 - 0.5 * leaves(q));
  if (uWave.w > 0.001) {
    float d = length(p - uWave.xy) - uWave.z;
    sun += 0.16 * uWave.w * exp(-d * d * 60.0);
  }
  vec3 wall = vec3(0.88, 0.875, 0.895);
  vec3 lit = vec3(1.0, 0.985, 0.955);
  vec3 col = mix(wall, lit, clamp(sun, 0.0, 1.0));
  // The penumbra warms up, the way sunlight does at the edge of a shadow.
  float rim = sun * (1.0 - sun) * 4.0;
  return col + vec3(0.03, 0.005, -0.03) * rim;
}
` },
  contours: { cap: 1500, source: `
// A height map drawn as contour lines, with the pointer as a hill the lines bend around.
float terrain(vec2 p) {
  float t = uT * 0.03;
  vec2 q = p * 0.75 + vec2(0.0, uScroll * 0.7);
  float h = noise(q + vec2(t, -t * 0.6)) * 1.1 + noise(q * 2.1 - t) * 0.34 + noise(q * 4.3 + t) * 0.08;
  vec2 d = p / zoom - uDent.xy;
  h += 0.62 * uDent.z * exp(-dot(d, d) * 3.2);
  if (uWave.w > 0.001) {
    float r = length(p / zoom - uWave.xy) - uWave.z;
    h += 0.2 * uWave.w * exp(-r * r * 26.0);
  }
  return h;
}

vec3 background(vec2 p, float aspect) {
  vec2 sheet = p * zoom;
  float e = 0.006;
  float h = terrain(sheet);
  float slope = length(vec2(terrain(sheet + vec2(e, 0.0)) - h, terrain(sheet + vec2(0.0, e)) - h)) / e;
  float lines = 15.0;
  float v = h * lines;
  float d = abs(fract(v) - 0.5);
  float px = 2.0 / uRes.y * zoom;
  float width = slope * lines * px;
  float line = 1.0 - smoothstep(width * 0.5, width * 1.5, 0.5 - d);
  float major = 1.0 - smoothstep(0.0, 1.0, abs(fract(v / 5.0) - 0.5) * 5.0 * 2.0);
  vec2 toAim = sheet / zoom - uDent.xy;
  float near = exp(-dot(toAim, toAim) * 2.2);
  vec3 ink = mix(vec3(0.3, 0.33, 0.45), flow(h * 0.3 + uT * 0.02), max(near * uDent.z, 0.28));
  vec3 col = mix(PEARL, PEARL2, smoothstep(-0.8, 0.8, h));
  return mix(col, ink, line * (0.2 + 0.26 * major + 0.4 * near * uDent.z));
}
` },
  needles: { cap: 1600, source: `
// A field of compass needles, every one of them aiming at the same point.
vec3 background(vec2 p, float aspect) {
  float cell = 0.052 * zoom;
  vec2 g = p / cell + vec2(0.0, uScroll * 12.0);
  vec2 id = floor(g);
  vec2 f = fract(g) - 0.5;
  vec2 centre = (id + 0.5 - vec2(0.0, uScroll * 12.0)) * cell;
  vec2 to = uDent.xy - centre;
  float dist = length(to);
  vec2 dir = to / max(dist, 0.001);
  float wander = noise(centre * 1.3 + uT * 0.12) * 0.5;
  float c = cos(wander), s = sin(wander);
  dir = vec2(dir.x * c - dir.y * s, dir.x * s + dir.y * c);
  float near = exp(-dist * dist * 2.6);
  float reach = 0.26 + 0.14 * near;
  if (uWave.w > 0.001) reach += 0.16 * uWave.w * exp(-pow(dist - uWave.z, 2.0) * 40.0);
  float along = clamp(dot(f, dir), -reach, reach);
  float d = length(f - dir * along);
  float px = 2.0 / uRes.y / cell;
  float line = 1.0 - smoothstep(0.035, 0.035 + px * 1.3, d);
  vec3 ink = mix(vec3(0.3, 0.33, 0.45), flow(dist * 0.32 - uT * 0.04), smoothstep(0.1, 0.8, near));
  vec3 col = mix(PEARL, PEARL2, smoothstep(-1.0, 1.0, p.y));
  return mix(col, ink, line * mix(0.24, 0.9, near));
}
` },
  mesh: { cap: 800, source: `
// Slow fields of colour that blend into each other, under a fine photographic grain.
vec3 background(vec2 p, float aspect) {
  float t = uT * 0.06;
  vec2 q = p * 0.62 * zoom + vec2(0.0, uScroll * 0.5);
  q += 0.55 * vec2(noise(q * 0.8 + t), noise(q * 0.8 - t + 3.0));
  vec3 col = vec3(0.97, 0.955, 0.945);
  vec2 a = q - vec2(-0.9 + sin(t) * 0.3, 0.5);
  vec2 b = q - vec2(0.9, 0.55 + cos(t * 0.8) * 0.3);
  vec2 c = q - vec2(0.3 + cos(t * 0.7) * 0.4, -0.7);
  vec2 d = q - vec2(-0.5, -0.8 + sin(t * 0.9) * 0.3);
  vec2 e = p - uDent.xy;
  col = mix(col, vec3(0.74, 0.83, 1.0), 0.9 * exp(-dot(a, a) * 1.0));
  col = mix(col, vec3(1.0, 0.8, 0.66), 0.9 * exp(-dot(b, b) * 1.1));
  col = mix(col, vec3(0.85, 0.76, 1.0), 0.85 * exp(-dot(c, c) * 1.0));
  col = mix(col, vec3(1.0, 0.74, 0.83), 0.8 * exp(-dot(d, d) * 1.3));
  col = mix(col, vec3(1.0), 0.5 * uDent.z * exp(-dot(e, e) * 3.0));
  if (uWave.w > 0.001) {
    float r = length(p - uWave.xy) - uWave.z;
    col = mix(col, vec3(1.0), 0.4 * uWave.w * exp(-r * r * 50.0));
  }
  float grain = fract(sin(dot(gl_FragCoord.xy + fract(uT) * 91.0, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
  return col + grain * 0.03;
}
` },
}

const VERTEX = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`

const fragment = (c, background) => `
precision highp float;
uniform vec2 uRes;
uniform vec2 uLight;
uniform float uT, uEdge, uScroll, uCalm;
uniform vec3 uDent;
uniform vec4 uWave;

const float TAU = 6.2831853;
const vec3 PEARL = ${vec3(c.pearl)};
const vec3 PEARL2 = ${vec3(c.pearl2)};
const vec3 PAPER = ${vec3(c.paper)};
const vec3 SHADE = ${vec3(c.shade)};
const vec3 P0 = ${vec3(c.cyan)};
const vec3 P1 = ${vec3(c.cobalt)};
const vec3 P2 = ${vec3(c.violet)};
const vec3 P3 = ${vec3(c.pink)};
const vec3 P4 = ${vec3(c.tangerine)};
const vec3 P5 = ${vec3(c.peach)};

vec2 grad(vec2 i) {
  vec3 p = fract(vec3(i.xyx) * 0.1031);
  p += dot(p, p.yzx + 33.33);
  float a = fract((p.x + p.y) * p.z) * TAU;
  return vec2(cos(a), sin(a));
}

float noise(vec2 p) {
  vec2 i = floor(p), f = p - i;
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  float a = dot(grad(i), f);
  float b = dot(grad(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
  float c = dot(grad(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
  float d = dot(grad(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.6;
}

vec3 flow(float t) {
  t = fract(t) * 6.0;
  float f = smoothstep(0.0, 1.0, fract(t));
  if (t < 1.0) return mix(P0, P1, f);
  if (t < 2.0) return mix(P1, P2, f);
  if (t < 3.0) return mix(P2, P3, f);
  if (t < 4.0) return mix(P3, P4, f);
  if (t < 5.0) return mix(P4, P5, f);
  return mix(P5, P0, f);
}

// Ink over the page: dyes the light underneath a little before covering it, so thin
// coverage stays a colour instead of fading to grey pastel.
vec3 ink(vec3 under, vec3 tint, float a) {
  a = clamp(a, 0.0, 1.0);
  vec3 dyed = under * mix(vec3(1.0), tint * 1.08, sqrt(a));
  return mix(dyed, tint, a * a * 0.92);
}

float gauss(float d, float w) { return exp(-(d * d) / (w * w)); }

// Phones see a narrow slice of the page, so the backgrounds zoom out there to keep their shape.
float zoom = 1.0;
${background}
void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  float aspect = uRes.x / uRes.y;
  vec2 p = (uv * 2.0 - 1.0) * vec2(aspect, 1.0);
  zoom = aspect < 1.0 ? 1.8 : 1.0;

  vec3 col = mix(background(p, aspect), PEARL2, uCalm * 0.3);

  if (uEdge > 0.001) {
    // A smooth minimum of the distances to the sides, so the line has no creases at the corners.
    vec2 toSide = vec2(aspect, 1.0) - abs(p);
    float inside = -0.05 * log(exp(-toSide.x / 0.05) + exp(-toSide.y / 0.05)) + 0.03;
    vec2 around = normalize(p / vec2(aspect, 1.0) + 0.0001);
    float t = atan(around.y, around.x) / TAU + 0.1 * noise(around * 1.1 + uT * 0.1) + uT * 0.06;
    float w = 0.012 + 0.016 * (0.5 + 0.5 * noise(around * 1.5 + uT * 0.24));
    col = ink(col, flow(t), uEdge * gauss(inside, w));
  }

  // Triangular dither, so the pale gradients never band in 8 bits.
  float n1 = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  float n2 = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 17.0, vec2(0.06711056, 0.00583715))));
  gl_FragColor = vec4(col + (n1 + n2 - 1.0) * 1.2 / 255.0, 1.0);
}
`

const UNIFORMS = ['uRes', 'uT', 'uEdge', 'uScroll', 'uCalm', 'uLight', 'uDent', 'uWave']

const finite = (value, fallback = 0) => (Number.isFinite(value) ? value : fallback)

/** Returns null without WebGL. Draws only when `render(state)` is called. */
export function createField(canvas, { scale = 0.6, background = 'silk' } = {}) {
  const options = { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'low-power' }
  const gl = canvas.getContext('webgl2', options) ?? canvas.getContext('webgl', options)
  if (!gl) return null

  const [tangerine, paper] = [hex('--tangerine'), hex('--paper')]
  const colours = {
    pearl: hex('--pearl'), pearl2: hex('--pearl-2'), paper, shade: hex('--shade'),
    cyan: hex('--cyan'), cobalt: hex('--cobalt'), violet: hex('--violet'), pink: hex('--pink'), tangerine,
    peach: tangerine.map((v, i) => v * 0.45 + paper[i] * 0.55),
  }

  let locations = null
  let chosen = BACKGROUNDS[background] ? background : 'silk'
  const build = () => {
    const shader = (type, source) => {
      const s = gl.createShader(type)
      gl.shaderSource(s, source)
      gl.compileShader(s)
      return s
    }
    const program = gl.createProgram()
    gl.attachShader(program, shader(gl.VERTEX_SHADER, VERTEX))
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER, fragment(colours, BACKGROUNDS[chosen].source)))
    gl.bindAttribLocation(program, 0, 'aPos')
    gl.linkProgram(program)
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return false
    gl.useProgram(program)
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer())
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW)
    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)
    locations = Object.fromEntries(UNIFORMS.map((name) => [name, gl.getUniformLocation(program, name)]))
    return true
  }
  if (!build()) return null

  canvas.addEventListener('webglcontextlost', (event) => {
    event.preventDefault()
    locations = null
  })
  canvas.addEventListener('webglcontextrestored', build)

  const resize = () => {
    const { clientWidth: w, clientHeight: h } = canvas
    if (!w || !h) return
    const detail = BACKGROUNDS[chosen].cap > 1000 ? 1.5 : 1
    const k = Math.min(scale * detail * Math.min(devicePixelRatio || 1, 2), BACKGROUNDS[chosen].cap / w)
    const width = Math.max(1, Math.round(w * k)), height = Math.max(1, Math.round(h * k))
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width
      canvas.height = height
    }
  }
  resize()

  const render = (state = {}) => {
    if (!locations || !canvas.width || !canvas.height) return
    const { time, light = [-0.5, 0.8], dent = [0, 0, 0], wave = [0, 0, 0, 0], scroll = 0, calm = 0, edge = 0 } = state
    gl.viewport(0, 0, canvas.width, canvas.height)
    gl.uniform2f(locations.uRes, canvas.width, canvas.height)
    gl.uniform1f(locations.uT, finite(time))
    gl.uniform1f(locations.uEdge, finite(edge))
    gl.uniform1f(locations.uScroll, finite(scroll))
    gl.uniform1f(locations.uCalm, finite(calm))
    gl.uniform2f(locations.uLight, finite(light[0]), finite(light[1]))
    gl.uniform3f(locations.uDent, finite(dent[0]), finite(dent[1]), finite(dent[2]))
    gl.uniform4f(locations.uWave, finite(wave[0]), finite(wave[1]), finite(wave[2]), finite(wave[3]))
    gl.drawArrays(gl.TRIANGLES, 0, 3)
  }

  const use = (name) => {
    if (!BACKGROUNDS[name] || name === chosen) return
    chosen = name
    build()
    resize()
  }

  return { resize, render, use }
}
