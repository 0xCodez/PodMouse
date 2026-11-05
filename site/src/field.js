// The page's background: a field of fine compass needles, every one aiming at the same point.
// The page moves that point through its story, and the colour gathers around wherever it lands.

const FALLBACK = {
  '--pearl': '#EFEEF4', '--pearl-2': '#F8F7FB',
  '--cobalt': '#2F5BFF', '--violet': '#8A4DFF', '--pink': '#FF3D9A', '--tangerine': '#FF8A3C', '--cyan': '#27D3FF',
}

const hex = (name) => {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  const match = /^#([0-9a-f]{6})$/i.exec(value) ?? /^#([0-9a-f]{6})$/i.exec(FALLBACK[name])
  return [0, 2, 4].map((i) => parseInt(match[1].slice(i, i + 2), 16) / 255)
}

const vec3 = ([r, g, b]) => `vec3(${r.toFixed(4)},${g.toFixed(4)},${b.toFixed(4)})`

const VERTEX = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`

const fragment = (c) => `
precision highp float;
uniform vec2 uRes;
uniform vec2 uAim;
uniform float uT, uEdge, uScroll, uCalm;
uniform vec4 uWave;

const float TAU = 6.2831853;
const vec3 PEARL = ${vec3(c.pearl)};
const vec3 PEARL2 = ${vec3(c.pearl2)};
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

vec3 needles(vec2 p) {
  float cell = 0.052;
  float shift = uScroll * 12.0;
  vec2 g = p / cell + vec2(0.0, shift);
  vec2 f = fract(g) - 0.5;
  vec2 centre = (floor(g) + 0.5 - vec2(0.0, shift)) * cell;

  vec2 to = uAim - centre;
  float dist = length(to);
  vec2 dir = to / max(dist, 0.001);
  // Each needle wavers a little, so the field looks alive even when the point stands still.
  float wander = noise(centre * 1.3 + uT * 0.12) * 0.5;
  float c = cos(wander), s = sin(wander);
  dir = vec2(dir.x * c - dir.y * s, dir.x * s + dir.y * c);

  float near = exp(-dist * dist * 2.6);
  float reach = 0.26 + 0.14 * near;
  float swell = 0.0;
  if (uWave.w > 0.001) {
    swell = uWave.w * exp(-pow(length(p - uWave.xy) - uWave.z, 2.0) * 40.0);
    reach += 0.18 * swell;
  }
  float along = clamp(dot(f, dir), -reach, reach);
  float d = length(f - dir * along);
  float px = 2.0 / uRes.y / cell;
  float line = 1.0 - smoothstep(0.03, 0.03 + px * 1.3, d);

  float heat = max(smoothstep(0.1, 0.8, near), swell);
  vec3 ink = mix(vec3(0.3, 0.33, 0.45), flow(dist * 0.32 - uT * 0.04), heat);
  vec3 page = mix(PEARL, PEARL2, smoothstep(-1.0, 1.0, p.y));
  return mix(page, ink, line * mix(0.24 - 0.11 * uCalm, 0.9, heat));
}

void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  float aspect = uRes.x / uRes.y;
  vec2 p = (uv * 2.0 - 1.0) * vec2(aspect, 1.0);

  vec3 col = needles(p);

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

const UNIFORMS = ['uRes', 'uT', 'uEdge', 'uScroll', 'uCalm', 'uAim', 'uWave']

const finite = (value, fallback = 0) => (Number.isFinite(value) ? value : fallback)

/** Returns null without WebGL. Draws only when `render(state)` is called. */
export function createField(canvas) {
  const options = { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'low-power' }
  const gl = canvas.getContext('webgl2', options) ?? canvas.getContext('webgl', options)
  if (!gl) return null

  const tangerine = hex('--tangerine')
  const colours = {
    pearl: hex('--pearl'), pearl2: hex('--pearl-2'),
    cyan: hex('--cyan'), cobalt: hex('--cobalt'), violet: hex('--violet'), pink: hex('--pink'), tangerine,
    peach: tangerine.map((v) => v * 0.45 + 0.55),
  }

  let locations = null
  const build = () => {
    const shader = (type, source) => {
      const s = gl.createShader(type)
      gl.shaderSource(s, source)
      gl.compileShader(s)
      return s
    }
    const program = gl.createProgram()
    gl.attachShader(program, shader(gl.VERTEX_SHADER, VERTEX))
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER, fragment(colours)))
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
    // Hairlines need every pixel, and this shader is cheap enough to give them all of them.
    const k = Math.min(Math.min(devicePixelRatio || 1, 2), 2880 / w)
    const width = Math.max(1, Math.round(w * k)), height = Math.max(1, Math.round(h * k))
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width
      canvas.height = height
    }
  }
  resize()

  const render = (state = {}) => {
    if (!locations || !canvas.width || !canvas.height) return
    const { time, aim = [0, 0], wave = [0, 0, 0, 0], scroll = 0, calm = 0, edge = 0 } = state
    gl.viewport(0, 0, canvas.width, canvas.height)
    gl.uniform2f(locations.uRes, canvas.width, canvas.height)
    gl.uniform1f(locations.uT, finite(time))
    gl.uniform1f(locations.uEdge, finite(edge))
    gl.uniform1f(locations.uScroll, finite(scroll))
    gl.uniform1f(locations.uCalm, finite(calm))
    gl.uniform2f(locations.uAim, finite(aim[0]), finite(aim[1]))
    gl.uniform4f(locations.uWave, finite(wave[0]), finite(wave[1]), finite(wave[2]), finite(wave[3]))
    gl.drawArrays(gl.TRIANGLES, 0, 3)
  }

  return { resize, render }
}
