// The page's light: a pearl room, a lens of white light with a flowing colour rim, the same
// ribbon along the viewport edges, a laser beam and a click ripple. Pale backgrounds swallow
// additive glow, so everything here is painted over the page in saturated ink with white cores.

const FALLBACK = {
  '--pearl': '#EEF0F5', '--pearl-2': '#F7F7FA', '--paper': '#FBFBFD',
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
uniform float uT, uRing, uEdge, uWash, uBeam;
uniform vec3 uBlob;
uniform vec2 uStretch;
uniform vec4 uBeamAB, uPulse;

const float TAU = 6.2831853;
const vec3 PEARL = ${vec3(c.pearl)};
const vec3 PEARL2 = ${vec3(c.pearl2)};
const vec3 PAPER = ${vec3(c.paper)};
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

void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  float aspect = uRes.x / uRes.y;
  vec2 p = (uv * 2.0 - 1.0) * vec2(aspect, 1.0);

  vec3 col = mix(PEARL, PEARL2, smoothstep(-1.0, 1.0, p.y));
  float drift = noise(p * 0.55 + vec2(uT * 0.02, -uT * 0.015));
  col += vec3(0.012, -0.002, -0.016) * drift + vec3(-0.008, 0.0, 0.012) * noise(p * 0.4 - uT * 0.017 + 9.0);

  if (uWash > 0.001) {
    float t = noise(p * 0.42 + uT * 0.03) * 0.55 + p.x * 0.09 / max(aspect, 0.4) + p.y * 0.07 + uT * 0.02;
    col = ink(col, flow(t), uWash * (0.2 + 0.14 * noise(p * 0.8 - uT * 0.04)));
  }

  // The blob, in units of its own radius.
  float R = max(uBlob.z * 2.0, 0.001);
  vec2 q = p - vec2(uBlob.x * aspect, uBlob.y);
  float speed = length(uStretch);
  if (speed > 0.0001) {
    // Stretched along its velocity, like a light being dragged.
    vec2 dir = uStretch / speed;
    float along = dot(q, dir);
    q += dir * along * (1.0 / (1.0 + min(speed, 1.0) * 1.1) - 1.0);
  }
  q /= R;
  float dist = length(q);
  if (dist < 3.4) {
    float fade = smoothstep(3.4, 2.1, dist);
    q += 0.05 * vec2(sin(q.y * 1.5 + uT * 0.5), cos(q.x * 1.3 - uT * 0.42));
    float angle = atan(q.y, q.x);
    float r = length(q);
    vec2 around = vec2(cos(angle), sin(angle));
    float wobble = 0.1 * noise(around * 0.8 + uT * 0.16);
    float d = r - 1.0 - wobble;
    float t = angle / TAU + 0.16 * noise(q * 0.7 + uT * 0.1) + uT * 0.035;

    if (uRing > 0.001) {
      float breath = 0.86 + 0.26 * noise(around * 1.1 + uT * 0.2 + 3.0);
      // A wide haze, a full ribbon, then two thin strands weaving through it.
      float haze = d > 0.0 ? exp(-d / 0.36) : exp(d / 0.16);
      col = ink(col, flow(t + 0.06), uRing * 0.56 * haze * breath * fade);
      float width = 0.2 + 0.07 * noise(around * 1.4 - uT * 0.26);
      col = ink(col, flow(t), uRing * gauss(d - 0.05, width) * breath * 1.04);
      float strandA = d + 0.07 + 0.07 * noise(around * 1.05 + uT * 0.34 + 11.0);
      float strandB = d - 0.09 + 0.09 * noise(around * 0.95 - uT * 0.29 + 23.0);
      col = ink(col, flow(t - 0.06), uRing * 0.95 * gauss(strandA, 0.05));
      col = ink(col, flow(t + 0.07), uRing * 0.72 * gauss(strandB, 0.04));
      col = mix(col, vec3(1.0), uRing * 0.55 * gauss(strandA + 0.01, 0.012));
    }
    float core = smoothstep(-0.02, -0.72, d);
    col = mix(col, PAPER + 0.03, core * (0.8 + 0.2 * uRing) * step(0.001, uBlob.z));
  }

  if (uEdge > 0.001) {
    // A smooth minimum of the distances to the sides, so the glow has no creases at the corners.
    vec2 toSide = vec2(aspect, 1.0) - abs(p);
    float inside = -0.09 * log(exp(-toSide.x / 0.09) + exp(-toSide.y / 0.09)) + 0.05;
    vec2 around = normalize(p / vec2(aspect, 1.0) + 0.0001);
    float angle = atan(around.y, around.x);
    float wobble = 0.5 + 0.5 * noise(around * 1.5 + uT * 0.24);
    float t = angle / TAU + 0.12 * noise(around * 1.1 + uT * 0.1) + uT * 0.05;
    float w = 0.05 + 0.1 * wobble;
    // Narrow windows must not let the tails meet in the middle.
    float reach = min(aspect, 1.0);
    float fade = smoothstep(0.7 * reach, 0.05, inside);
    fade *= fade;
    col = ink(col, flow(t + 0.07), uEdge * 0.62 * exp(-inside / (w * 1.3)) * fade);
    col = ink(col, flow(t), uEdge * gauss(inside, w * 0.85) * 1.04);
    float strand = inside - w * (0.5 + 0.4 * noise(around * 2.1 - uT * 0.3 + 5.0));
    col = ink(col, flow(t - 0.06), uEdge * 0.8 * gauss(strand, 0.022));
    col = mix(col, vec3(1.0), uEdge * 0.8 * gauss(inside, 0.01));
  }

  if (uBeam > 0.001) {
    vec2 a = uBeamAB.xy * vec2(aspect, 1.0), b = uBeamAB.zw * vec2(aspect, 1.0);
    vec2 ab = b - a;
    float s = clamp(dot(p - a, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
    float d = length(p - a - ab * s);
    float rise = mix(0.25, 1.0, s * s) * smoothstep(0.0, 0.08, s);
    float t = s * 0.3 - uT * 0.09;
    col = ink(col, flow(t), uBeam * rise * 0.66 * exp(-d / 0.05));
    col = ink(col, flow(t + 0.05), uBeam * rise * gauss(d, 0.014));
    col = mix(col, vec3(1.0), uBeam * rise * 0.92 * gauss(d, 0.0045));
    float hit = length(p - b);
    col = ink(col, flow(uT * 0.08 + 0.2), uBeam * 0.82 * exp(-hit / 0.05));
    col = mix(col, vec3(1.0), uBeam * gauss(hit, 0.03));
  }

  if (uPulse.w > 0.001) {
    vec2 o = p - uPulse.xy * vec2(aspect, 1.0);
    float radius = uPulse.z * 2.0;
    float d = length(o) - radius;
    float w = 0.018 + radius * 0.13;
    float t = atan(o.y, o.x) / TAU + uT * 0.08;
    float hollow = smoothstep(0.0, 0.35, length(o) / max(radius, 0.001));
    col = ink(col, flow(t), uPulse.w * 0.78 * hollow * (d < 0.0 ? exp(d / (w * 0.9)) : exp(-d / (w * 0.8))));
    col = mix(col, vec3(1.0), uPulse.w * 0.85 * gauss(d, w * 0.22));
  }

  // Triangular dither, so the pale gradients never band in 8 bits.
  float n1 = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  float n2 = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 17.0, vec2(0.06711056, 0.00583715))));
  gl_FragColor = vec4(col + (n1 + n2 - 1.0) * 1.2 / 255.0, 1.0);
}
`

const UNIFORMS = ['uRes', 'uT', 'uRing', 'uEdge', 'uWash', 'uBeam', 'uBlob', 'uStretch', 'uBeamAB', 'uPulse']

const finite = (value, fallback = 0) => (Number.isFinite(value) ? value : fallback)

/** Returns null without WebGL. Draws only when `render(state)` is called. */
export function createField(canvas, { scale = 0.6 } = {}) {
  const options = { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'low-power' }
  const gl = canvas.getContext('webgl2', options) ?? canvas.getContext('webgl', options)
  if (!gl) return null

  const [tangerine, paper] = [hex('--tangerine'), hex('--paper')]
  const colours = {
    pearl: hex('--pearl'), pearl2: hex('--pearl-2'), paper,
    cyan: hex('--cyan'), cobalt: hex('--cobalt'), violet: hex('--violet'), pink: hex('--pink'), tangerine,
    peach: tangerine.map((v, i) => v * 0.45 + paper[i] * 0.55),
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
    const k = Math.min(scale * Math.min(devicePixelRatio || 1, 2), 960 / w)
    const width = Math.max(1, Math.round(w * k)), height = Math.max(1, Math.round(h * k))
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width
      canvas.height = height
    }
  }
  resize()

  const render = (state = {}) => {
    if (!locations || !canvas.width || !canvas.height) return
    const { time, blob = [0, 0, 0.3], stretch = [0, 0], ring = 0, edge = 0, wash = 0, beamA = [0, 0], beamB = [0, 0], beam = 0, pulse = [0, 0, 0, 0] } = state
    gl.viewport(0, 0, canvas.width, canvas.height)
    gl.uniform2f(locations.uRes, canvas.width, canvas.height)
    gl.uniform1f(locations.uT, finite(time))
    gl.uniform1f(locations.uRing, finite(ring))
    gl.uniform1f(locations.uEdge, finite(edge))
    gl.uniform1f(locations.uWash, finite(wash))
    gl.uniform1f(locations.uBeam, finite(beam))
    gl.uniform3f(locations.uBlob, finite(blob[0]), finite(blob[1]), finite(blob[2]))
    gl.uniform2f(locations.uStretch, finite(stretch[0]), finite(stretch[1]))
    gl.uniform4f(locations.uBeamAB, finite(beamA[0]), finite(beamA[1]), finite(beamB[0]), finite(beamB[1]))
    gl.uniform4f(locations.uPulse, finite(pulse[0]), finite(pulse[1]), finite(pulse[2]), finite(pulse[3]))
    gl.drawArrays(gl.TRIANGLES, 0, 3)
  }

  return { resize, render }
}
