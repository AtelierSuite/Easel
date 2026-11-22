// The canvas, drawn on the GPU: the picture's parts as the engine cuts them
// (CanvasParts.swift), mixed with the engine's own blend formulas, and the
// stroke being drawn shown inside the layer it lands on.

const MODES = [
  "normal", "dissolve", "multiply", "darken", "colorBurn", "plusDarker", "darkerColor",
  "screen", "lighten", "colorDodge", "plusLighter", "lighterColor",
  "overlay", "softLight", "hardLight", "vividLight", "linearLight", "pinLight", "hardMix",
  "difference", "exclusion", "subtract", "divide", "hue", "saturation", "color", "luminosity",
];

const VERTEX = `#version 300 es
in vec2 corner;
out vec2 uv;
uniform bool flip;
void main() {
  uv = corner;
  gl_Position = vec4(corner.x * 2.0 - 1.0, (flip ? 1.0 - corner.y : corner.y) * 2.0 - 1.0, 0.0, 1.0);
}`;

// Every texture keeps the picture's top row first. Colours are premultiplied.
// Mirrors blend() in Portable/CoreGraphics/Raster.swift and BlendModes.swift.
const FRAGMENT = `#version 300 es
precision highp float;
in vec2 uv;
out vec4 result;
uniform sampler2D backdrop;
uniform sampler2D layer;
uniform sampler2D ink;
uniform int mode;
uniform float opacity;
uniform int inkMode;
uniform float inkOpacity;
uniform bool bake;
uniform vec2 canvasPixels;
uniform vec2 shift;

float lum(vec3 c) { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; }
vec3 clipColor(vec3 c) {
  float l = lum(c), n = min(c.r, min(c.g, c.b)), x = max(c.r, max(c.g, c.b));
  if (n < 0.0) c = l + (c - l) * l / max(l - n, 1e-6);
  if (x > 1.0) c = l + (c - l) * (1.0 - l) / max(x - l, 1e-6);
  return c;
}
vec3 setLum(vec3 c, float l) { return clipColor(c + (l - lum(c))); }
float sat(vec3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
vec3 setSat(vec3 c, float s) {
  float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
  return mx > mn ? (c - mn) * s / (mx - mn) : vec3(0.0);
}
float burn(float b, float s) { return b >= 1.0 ? 1.0 : s <= 0.0 ? 0.0 : max(1.0 - (1.0 - b) / s, 0.0); }
float dodge(float b, float s) { return b <= 0.0 ? 0.0 : s >= 1.0 ? 1.0 : min(b / (1.0 - s), 1.0); }
float channel(int m, float b, float s) {
  switch (m) {
  case 2: return b * s;
  case 3: return min(b, s);
  case 4: return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s));
  case 7: return b + s - b * s;
  case 8: return max(b, s);
  case 9: return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s)));
  case 12: return b <= 0.5 ? 2.0 * s * b : 1.0 - 2.0 * (1.0 - s) * (1.0 - b);
  case 13: {
    if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);
    float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
    return b + (2.0 * s - 1.0) * (d - b);
  }
  case 14: return s <= 0.5 ? 2.0 * s * b : 1.0 - 2.0 * (1.0 - s) * (1.0 - b);
  case 15: return s <= 0.5 ? burn(b, 2.0 * s) : dodge(b, 2.0 * s - 1.0);
  case 16: return clamp(b + 2.0 * s - 1.0, 0.0, 1.0);
  case 17: return s <= 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0);
  case 18: return b + s >= 1.0 - 1e-4 ? 1.0 : 0.0;
  case 19: return abs(b - s);
  case 20: return b + s - 2.0 * b * s;
  case 21: return max(b - s, 0.0);
  case 22: return s <= 0.0 ? (b <= 0.0 ? 0.0 : 1.0) : min(b / s, 1.0);
  default: return s;
  }
}
float dissolveThreshold(ivec2 p) {
  uint hash = uint(p.x) * 0x8DA6B343u ^ uint(p.y) * 0xD8163841u;
  hash = (hash ^ (hash >> 13)) * 0x5BD1E995u;
  hash ^= hash >> 15;
  return float(hash & 0xFFFFu) / 65536.0;
}

void main() {
  vec2 at = uv - shift;
  vec4 s = all(greaterThanEqual(at, vec2(0.0))) && all(lessThanEqual(at, vec2(1.0))) ? texture(layer, at) : vec4(0.0);
  if (inkMode != 0) {
    float cover = texture(ink, uv).a * inkOpacity;
    s = inkMode == 1 ? texture(ink, uv) * inkOpacity + s * (1.0 - cover) : s * (1.0 - cover);
  }
  if (bake) { result = s; return; }
  s *= opacity;
  vec4 d = texture(backdrop, uv);
  float sa = s.a, da = d.a;
  if (mode == 0) { result = s + d * (1.0 - sa); return; }
  if (mode == 10) { result = clamp(s + d, 0.0, 1.0); return; }
  if (mode == 5) {
    float a = min(sa + da, 1.0);
    result = vec4(clamp(a - ((da - d.rgb) + (sa - s.rgb)), 0.0, 1.0), a);
    return;
  }
  if (sa <= 0.0) { result = d; return; }
  vec3 cs = s.rgb / sa;
  if (mode == 1) {
    // The engine compares the layer's opacity as stored, in 8 bits.
    ivec2 pixel = ivec2(floor(uv * canvasPixels));
    result = floor(sa * 255.0 + 0.5) / 255.0 > dissolveThreshold(pixel) ? vec4(cs, 1.0) : d;
    return;
  }
  if (da <= 0.0) { result = s; return; }
  vec3 cb = d.rgb / da;
  vec3 mixed;
  if (mode == 23) mixed = setLum(setSat(cs, sat(cb)), lum(cb));
  else if (mode == 24) mixed = setLum(setSat(cb, sat(cs)), lum(cb));
  else if (mode == 25) mixed = setLum(cs, lum(cb));
  else if (mode == 26) mixed = setLum(cb, lum(cs));
  else if (mode == 6) mixed = (cb.r + cb.g + cb.b) <= (cs.r + cs.g + cs.b) ? cb : cs;
  else if (mode == 11) mixed = (cb.r + cb.g + cb.b) >= (cs.r + cs.g + cs.b) ? cb : cs;
  else mixed = vec3(channel(mode, cb.r, cs.r), channel(mode, cb.g, cs.g), channel(mode, cb.b, cs.b));
  vec3 c = s.rgb * (1.0 - da) + d.rgb * (1.0 - sa) + mixed * (sa * da);
  result = vec4(clamp(c, 0.0, 1.0), sa + da - sa * da);
}`;

const SHOW = `#version 300 es
precision highp float;
in vec2 uv;
out vec4 result;
uniform sampler2D picture;
void main() { result = texture(picture, uv); }`;

export class GPUCanvas {
  /** Throws when the browser has no WebGL 2. */
  constructor(element) {
    this.element = element;
    this.parts = [];
    this.key = null;
    this.width = 0;
    this.height = 0;
    this.stroke = null;
    this.frame = null;
    this.ink = document.createElement("canvas");
    this.setUp();
    element.addEventListener("webglcontextlost", (event) => {
      event.preventDefault();
      this.lost = true;
    });
    element.addEventListener("webglcontextrestored", () => {
      this.lost = false;
      this.setUp();
      this.key = null;
      this.onRestore?.();
    });
  }

  setUp() {
    const gl = this.element.getContext("webgl2", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false });
    if (!gl) throw new Error("WebGL 2 is unavailable");
    this.gl = gl;
    this.maxSize = Math.min(4096, gl.getParameter(gl.MAX_TEXTURE_SIZE));
    this.mix = this.program(VERTEX, FRAGMENT);
    this.show = this.program(VERTEX, SHOW);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    for (const program of [this.mix, this.show]) {
      const at = gl.getAttribLocation(program, "corner");
      if (at < 0) continue;
      gl.enableVertexAttribArray(at);
      gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
    }
    this.framebuffer = gl.createFramebuffer();
    this.empty = this.texture(1, 1, new Uint8Array(4));
    this.parts = [];
    this.targets = null;
    this.below = null;
    this.inkTexture = null;
  }

  program(vertexSource, fragmentSource) {
    const gl = this.gl;
    const compile = (type, source) => {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
      return shader;
    };
    const program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
    gl.bindAttribLocation(program, 0, "corner");
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    program.uniforms = {};
    const count = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < count; i++) {
      const name = gl.getActiveUniform(program, i).name;
      program.uniforms[name] = gl.getUniformLocation(program, name);
    }
    return program;
  }

  texture(width, height, pixels = null) {
    const gl = this.gl;
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    return texture;
  }

  /** The engine's parts (the "canvas" request's answer), all or just the active one. */
  setParts(response, payload) {
    if (this.lost) return;
    const gl = this.gl;
    const { width, height } = response;
    if (width !== this.width || height !== this.height) {
      this.width = width;
      this.height = height;
      this.element.width = width;
      this.element.height = height;
      this.ink.width = width;
      this.ink.height = height;
      for (const target of this.targets ?? []) gl.deleteTexture(target);
      this.targets = [this.texture(width, height), this.texture(width, height)];
      if (this.below) gl.deleteTexture(this.below);
      this.below = this.texture(width, height);
      if (this.inkTexture) gl.deleteTexture(this.inkTexture);
      this.inkTexture = this.texture(width, height);
      this.key = null;
    }
    const whole = response.key !== this.key;
    if (whole) {
      for (const part of this.parts) gl.deleteTexture(part.texture);
      this.parts = response.parts.map((part) => ({ ...part, texture: null }));
      this.key = response.key;
    } else {
      response.parts.forEach((part, index) => Object.assign(this.parts[index], part));
    }
    const bytes = width * height * 4;
    response.rendered.forEach((index, n) => {
      const part = this.parts[index];
      const pixels = payload.subarray(n * bytes, (n + 1) * bytes);
      if (part.texture) {
        gl.bindTexture(gl.TEXTURE_2D, part.texture);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      } else {
        part.texture = this.texture(width, height, pixels);
      }
    });
    this.belowValid = false;
    if (response.rendered.includes(this.activeIndex)) this.shift = null;
    this.draw();
  }

  /** Shows the layer being moved `dx`, `dy` picture pixels from where it is, until the engine's moved picture comes. */
  moveActive(dx, dy) {
    const scale = this.scale ?? 1;
    this.shift = [dx / scale / this.width, dy / scale / this.height];
    this.draw();
  }

  /** Leaves the active part out, while a tool shows it changed in its place. */
  hideActive(hidden) {
    if (this.hidden === hidden) return;
    this.hidden = hidden;
    this.draw();
  }

  /** Whether the parts held fit `key`, so only the active part need be fetched. */
  fits(key) {
    return key === this.key && this.parts.every((part) => part.texture);
  }

  get activeIndex() {
    return this.parts.findIndex((part) => part.active);
  }

  // ------------------------------------------------------------ Strokes

  /**
   * Starts showing a stroke. `style`: { color, opacity, erase }; the stroke's
   * shape is drawn by `paint(context)` into the ink, in canvas pixels.
   */
  beginStroke(style) {
    this.stroke = style;
  }

  updateStroke(paint) {
    if (!this.stroke || this.lost) return;
    const context = this.ink.getContext("2d");
    context.setTransform(1, 0, 0, 1, 0, 0);
    context.clearRect(0, 0, this.width, this.height);
    paint(context, 1 / (this.scale ?? 1));
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.inkTexture);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, this.ink);
    this.draw();
  }

  /**
   * Leaves the stroke in its layer until the engine's painting of it comes
   * back, so the next stroke can begin at once.
   */
  endStroke() {
    const stroke = this.stroke;
    this.stroke = null;
    if (!stroke || this.lost) return;
    const index = this.activeIndex;
    const part = this.parts[index];
    if (part?.texture) {
      const baked = this.texture(this.width, this.height);
      this.pass(baked, { layer: part.texture, inkMode: stroke.erase ? 2 : 1, inkOpacity: stroke.opacity, bake: true });
      this.gl.deleteTexture(part.texture);
      part.texture = baked;
    } else if (!stroke.erase) {
      // Over the whole picture, when the layer can't be shown apart.
      this.overlay ??= this.texture(this.width, this.height);
      const baked = this.texture(this.width, this.height);
      this.pass(baked, { layer: this.overlay, inkMode: 1, inkOpacity: stroke.opacity, bake: true });
      this.gl.deleteTexture(this.overlay);
      this.overlay = baked;
    }
    this.draw();
  }

  cancelStroke() {
    this.stroke = null;
    this.draw();
  }

  /** Drops what was shown over the picture once the engine's own picture is in. */
  clearOverlay() {
    if (this.overlay) this.gl.deleteTexture(this.overlay);
    this.overlay = null;
  }

  // ------------------------------------------------------------ Drawing

  draw() {
    this.dirty = true;
    if (this.frame || this.lost) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.composite();
    });
  }

  pass(target, { backdrop = this.empty, layer, mode = 0, opacity = 1, inkMode = 0, inkOpacity = 1, bake = false, shift = [0, 0] }) {
    const gl = this.gl, program = this.mix, u = program.uniforms;
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target, 0);
    gl.viewport(0, 0, this.width, this.height);
    gl.useProgram(program);
    gl.bindVertexArray(this.vao);
    gl.disable(gl.BLEND);
    const bind = (unit, texture, name) => {
      gl.activeTexture(gl.TEXTURE0 + unit);
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.uniform1i(u[name], unit);
    };
    bind(0, backdrop, "backdrop");
    bind(1, layer, "layer");
    bind(2, inkMode ? this.inkTexture : this.empty, "ink");
    gl.uniform1i(u.mode, mode);
    gl.uniform1f(u.opacity, opacity);
    gl.uniform1i(u.inkMode, inkMode);
    gl.uniform1f(u.inkOpacity, inkOpacity);
    gl.uniform1i(u.bake, bake ? 1 : 0);
    gl.uniform1i(u.flip, 0);
    gl.uniform2f(u.shift, shift[0], shift[1]);
    gl.uniform2f(u.canvasPixels, this.width * (this.scale ?? 1), this.height * (this.scale ?? 1));
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  clear(target) {
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, target, 0);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
  }

  /** Mixes the parts bottom first; what is beneath the active part is kept, as it doesn't change while painting. */
  composite() {
    if (!this.targets || this.lost) return;
    this.dirty = false;
    const gl = this.gl;
    const active = this.activeIndex;
    let [from, to] = this.targets;
    let start = 0;
    if (active > 0 && this.belowValid) {
      this.copy(this.below, from);
      start = active;
    } else {
      this.clear(from);
    }
    for (let index = start; index < this.parts.length; index++) {
      const part = this.parts[index];
      if (!part.texture) continue;
      if (index === active && active > 0 && !this.belowValid) {
        this.copy(from, this.below);
        this.belowValid = true;
      }
      const inking = index === active && this.stroke;
      this.pass(to, {
        backdrop: from, layer: part.texture, mode: Math.max(0, MODES.indexOf(part.blendMode)), opacity: index === active && this.hidden ? 0 : part.opacity,
        inkMode: inking ? (this.stroke.erase ? 2 : 1) : 0, inkOpacity: this.stroke?.opacity ?? 1,
        shift: index === active && this.shift ? this.shift : [0, 0],
      });
      [from, to] = [to, from];
    }
    if (active < 0 && (this.overlay || (this.stroke && !this.stroke.erase))) {
      this.pass(to, { backdrop: from, layer: this.overlay ?? this.empty, inkMode: this.stroke && !this.stroke.erase ? 1 : 0, inkOpacity: this.stroke?.opacity ?? 1 });
      [from, to] = [to, from];
    }
    this.result = from;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, this.width, this.height);
    gl.useProgram(this.show);
    gl.uniform1i(this.show.uniforms.flip, 1);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, from);
    gl.uniform1i(this.show.uniforms.picture, 0);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  copy(source, target) {
    this.pass(target, { layer: source, bake: true });
  }

  /** The picture's colour at a pixel of the canvas as shown, straight alpha, 0–255. */
  colorAt(x, y) {
    if (!this.result || this.lost) return null;
    if (this.dirty) this.composite();
    const gl = this.gl;
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.result, 0);
    const pixel = new Uint8Array(4);
    gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
    const a = pixel[3];
    if (a === 0) return [0, 0, 0, 0];
    return [...[0, 1, 2].map((i) => Math.min(255, Math.round((pixel[i] * 255) / a))), a];
  }
}
