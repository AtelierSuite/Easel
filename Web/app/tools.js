// The tools, grouped as the Apple apps group them, with their options, and
// what a finger, pen or mouse does with them on the canvas.
//
// A tool is an object with:
//   options()                  the HTML of its options, or ""
//   bind(element)              wires up those options once they're shown
//   begin(point, event)        a finger, pen or mouse came down at `point`, in the picture's pixels
//   update(points)             it moved; `points` are every point since, each { x, y, pressure }
//   end()                      it lifted
//   cancel()                   a second finger came down, or the browser took the pointer
// Tools show what they're doing through the window's canvas (canvas.js) and
// change the picture through window.edit(), which the engine carries out.

import { t } from "./i18n.js";
import { openMenu } from "../design/menus.js";

const icon = (path) => `<svg class="ds-icon" viewBox="0 0 16 16" aria-hidden="true">${path}</svg>`;
const line = (d) => `<path d="${d}" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>`;
const escapeHTML = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const hexToColor = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).concat(1);
const toHex = (r, g, b) => `#${[r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("")}`;

const TURN_THRESHOLD = Math.PI / 18;

const ICONS = {
  move: line("M8 1.5v13M1.5 8h13M6 3.5l2-2 2 2M6 12.5l2 2 2-2M3.5 6l-2 2 2 2M12.5 6l2 2-2 2"),
  transform: line("M3.5 3.5l9 1.5-1 8-9-1.5z") + '<rect x="2" y="2" width="3" height="3" fill="currentColor"/><rect x="11" y="3.5" width="3" height="3" fill="currentColor"/><rect x="10" y="11.5" width="3" height="3" fill="currentColor"/><rect x="1" y="10" width="3" height="3" fill="currentColor"/>',
  select: '<rect x="2.5" y="3.5" width="11" height="9" fill="none" stroke="currentColor" stroke-dasharray="2 1.5"/>',
  crop: line("M4.5 1.5v10h10M1.5 4.5h10v10"),
  brush: line("M14 2L7.5 9.5M7 10c-2 0-3 1.5-3 3s-1.5 1.5-2.5 1.5c3 1 6.5 0 6.5-3z"),
  eraser: line("M9.5 2.5l4 4-6.5 6.5H4.5l-3-3zM5.5 6.5l4 4M7 14.5h7.5"),
  fill: line("M7 2.5l5.5 5.5-5 5-5.5-5.5zM2 8h10.5M14 10.5s1 1.5 1 2.2a1 1 0 0 1-2 0c0-.7 1-2.2 1-2.2z"),
  gradient: '<defs><linearGradient id="tool-gradient"><stop offset="0" stop-color="currentColor"/><stop offset="1" stop-color="currentColor" stop-opacity="0"/></linearGradient></defs><rect x="2" y="2" width="12" height="12" fill="url(#tool-gradient)" stroke="currentColor"/>',
  eyedropper: line("M10.5 2.5l3 3M12 1.5l2.5 2.5-2 2-2.5-2.5zM10.5 5.5l-7 7-1 2.5 2.5-1 7-7"),
  liquify: line("M1.5 5c2-2 4 2 6.5 0s4.5-2 6.5 0M1.5 11c2-2 4 2 6.5 0s4.5-2 6.5 0"),
  censor: '<rect x="2.5" y="2.5" width="11" height="11" fill="none" stroke="currentColor"/><rect x="2.5" y="2.5" width="3.7" height="3.7" fill="currentColor"/><rect x="9.8" y="2.5" width="3.7" height="3.7" fill="currentColor"/><rect x="6.2" y="6.2" width="3.7" height="3.7" fill="currentColor"/><rect x="2.5" y="9.8" width="3.7" height="3.7" fill="currentColor"/><rect x="9.8" y="9.8" width="3.7" height="3.7" fill="currentColor"/>',
  tone: '<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor"/><path d="M8 2a6 6 0 0 0 0 12z" fill="currentColor"/>',
  heal: line("M3 9.5l6.5-6.5a2.1 2.1 0 0 1 3 3L6 12.5a2.1 2.1 0 0 1-3-3zM6.5 6l3.5 3.5"),
  clone: line("M5.5 1.5h5v4h-5zM8 5.5v3M2.5 8.5h11v3h-11zM4 14.5h8"),
  text: line("M3 3.5h10M8 3.5v10M6 13.5h4"),
  shape: '<rect x="1.5" y="1.5" width="8" height="8" fill="none" stroke="currentColor"/><circle cx="10" cy="10" r="4.5" fill="none" stroke="currentColor"/>',
  pen: line("M8 1.5l4 7-4 6-4-6zM8 1.5v6M8 14.5v1") + '<circle cx="8" cy="9" r="1.2" fill="currentColor"/>',
  nodes: line("M2.5 12.5C4 5 12 11 13.5 3.5") + '<rect x="1" y="11" width="3" height="3" fill="currentColor"/><rect x="12" y="2" width="3" height="3" fill="currentColor"/>',
};

const LABELS = {
  move: "Tool.Move", transform: "Tool.Transform", select: "Tool.Select", crop: "Tool.Crop",
  brush: "Tool.Brush", eraser: "Tool.Eraser", fill: "Tool.Fill", gradient: "Tool.Gradient", eyedropper: "Tool.Eyedropper",
  liquify: "Tool.Liquify", censor: "Tool.Censor", tone: "Tool.Tone", heal: "Tool.Heal", clone: "Tool.Clone",
  text: "Tool.Text", shape: "Tool.Shape", pen: "Tool.Pen", nodes: "Tool.Nodes",
};

const GROUPS = [
  ["move", "transform", "select", "crop"],
  ["brush", "eraser", "fill", "gradient", "eyedropper"],
  ["liquify", "censor", "tone", "heal", "clone"],
  ["text", "shape", "pen", "nodes"],
];

// ------------------------------------------------------------ Options

function slider(key, label, min, max, value, unit = "") {
  return `
    <label class="ds-slider app__option">
      <span class="app__option-label">${escapeHTML(t(label))}</span>
      <input type="range" data-option="${key}" min="${min}" max="${max}" step="1" value="${value}" aria-label="${escapeHTML(t(label))}">
      <span class="ds-numeric app__option-value" data-value="${key}" data-unit="${unit}">${value}${unit}</span>
    </label>`;
}

function colorWell(color) {
  const label = escapeHTML(t("Options.Color"));
  return `<input type="color" class="ds-color-well" data-option="color" value="${color}" aria-label="${label}" title="${label}">`;
}

function choice(key, label, options, value) {
  const name = escapeHTML(t(label));
  return `
    <span class="ds-popup ds-popup--xs app__option" title="${name}">
      <select class="ds-popup__select" data-option="${key}" aria-label="${name}">
        ${options.map(([id, text]) => `<option value="${id}"${id === value ? " selected" : ""}>${escapeHTML(t(text))}</option>`).join("")}
      </select>
      <svg class="ds-icon ds-popup__chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>
    </span>`;
}

function toggle(key, label, checked) {
  return `<label class="ds-switch app__option"><input type="checkbox" role="switch" data-option="${key}"${checked ? " checked" : ""}>${escapeHTML(t(label))}</label>`;
}

function action(name, label, pressed = null) {
  const pressing = pressed === null ? "" : ` aria-pressed="${pressed}"`;
  return `<button type="button" class="ds-button ds-button--bordered ds-button--xs app__option" data-tool-action="${name}"${pressing}>${escapeHTML(t(label))}</button>`;
}

/** Calls `perform(name)` when one of the options' buttons is pressed. */
function bindActions(element, perform) {
  for (const button of element.querySelectorAll("[data-tool-action]")) {
    button.addEventListener("click", () => perform(button.dataset.toolAction, button));
  }
}

/** Calls `change(key, value)` as each option moves, and keeps its shown value in step. */
function bindOptions(element, change) {
  for (const input of element.querySelectorAll("[data-option]")) {
    input.addEventListener(input.tagName === "SELECT" || input.type === "checkbox" ? "change" : "input", () => {
      const key = input.dataset.option;
      if (input.tagName === "SELECT" || key === "color") {
        change(key, input.value);
        return;
      }
      if (input.type === "checkbox") {
        change(key, input.checked);
        return;
      }
      const value = Number(input.value);
      const shown = element.querySelector(`[data-value="${key}"]`);
      if (shown) shown.textContent = `${value}${shown.dataset.unit}`;
      change(key, value);
    });
  }
}

// ------------------------------------------------------------ Tools

/** Brush and Eraser: the stroke shows in its layer as it's drawn, and the engine paints it when it lifts. */
class BrushTool {
  constructor(tools, { erases, size, softness }) {
    this.tools = tools;
    this.erases = erases;
    this.settings = { size, opacity: 1, softness };
  }

  options() {
    const { size, opacity, softness } = this.settings;
    return (this.erases ? "" : colorWell(this.tools.color))
      + slider("size", "Options.Size", 1, 400, size)
      + slider("opacity", "Options.Opacity", 1, 100, Math.round(opacity * 100), "%")
      + slider("softness", "Options.Softness", 0, 100, Math.round(softness * 100), "%");
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "color") this.tools.color = value;
      else this.settings[key] = key === "size" ? value : value / 100;
    });
  }

  begin(point) {
    this.stroke = { ...this.settings, color: this.tools.color, points: [point] };
    // On a mask the brush hides the layer, shown as it goes; what the eraser brings back shows once painted.
    const mask = this.tools.window.paintsMask();
    const opacity = mask && (this.erases || this.tools.window.selectedRow()?.type === "adjustment") ? 0 : this.settings.opacity;
    this.tools.window.canvasView.beginStroke({ color: this.stroke.color, opacity, erase: mask || this.erases });
    this.show();
  }

  update(points) {
    if (!this.stroke) return;
    this.stroke.points.push(...points);
    this.show();
  }

  show() {
    const stroke = this.stroke;
    const selection = this.tools.window.info?.selection;
    this.tools.window.canvasView.updateStroke((context, scale) => {
      if (selection) {
        context.save();
        context.setTransform(scale, 0, 0, scale, 0, 0);
        context.clip(new Path2D(selection), "evenodd");
      }
      drawStroke(context, stroke, scale);
      if (selection) context.restore();
    });
  }

  end() {
    const stroke = this.stroke;
    this.stroke = null;
    if (!stroke) return;
    this.tools.window.canvasView.endStroke();
    this.tools.window.edit("stroke", {
      kind: this.erases ? "erase" : "paint",
      points: stroke.points.flatMap((p) => [p.x, p.y, p.pressure]),
      size: stroke.size,
      opacity: stroke.opacity,
      softness: stroke.softness,
      color: hexToColor(stroke.color),
    });
  }

  cancel() {
    this.stroke = null;
    this.tools.window.canvasView.cancelStroke();
  }
}

/** The stroke's shape, near enough to what the engine paints: pressure thins it as Stroke.width(at:) does. */
function drawStroke(context, stroke, scale) {
  const { points, size, softness } = stroke;
  context.setTransform(scale, 0, 0, scale, 0, 0);
  context.strokeStyle = context.fillStyle = stroke.color;
  context.lineCap = context.lineJoin = "round";
  if (softness > 0) context.filter = `blur(${size * softness * 0.25 * scale}px)`;
  const width = (p) => size * (0.2 + 0.8 * Math.min(Math.max(p.pressure, 0), 1));
  if (points.length === 1) {
    context.beginPath();
    context.arc(points[0].x, points[0].y, width(points[0]) / 2, 0, Math.PI * 2);
    context.fill();
  } else if (points.every((p) => p.pressure >= 1)) {
    context.lineWidth = size;
    context.beginPath();
    context.moveTo(points[0].x, points[0].y);
    for (const p of points.slice(1)) context.lineTo(p.x, p.y);
    context.stroke();
  } else {
    for (let i = 1; i < points.length; i++) {
      context.lineWidth = (width(points[i - 1]) + width(points[i])) / 2;
      context.beginPath();
      context.moveTo(points[i - 1].x, points[i - 1].y);
      context.lineTo(points[i].x, points[i].y);
      context.stroke();
    }
  }
  context.filter = "none";
}

/** Fill: a tap fills the run of similar colour around it. */
class FillTool {
  constructor(tools) {
    this.tools = tools;
    this.tolerance = 0.12;
  }

  options() {
    return colorWell(this.tools.color) + slider("tolerance", "Options.Tolerance", 0, 100, Math.round(this.tolerance * 100), "%");
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "color") this.tools.color = value;
      else this.tolerance = value / 100;
    });
  }

  begin(point) {
    this.point = point;
  }

  update() {}

  end() {
    if (!this.point) return;
    this.tools.window.edit("fill", { x: this.point.x, y: this.point.y, color: hexToColor(this.tools.color), tolerance: this.tolerance });
    this.point = null;
  }

  cancel() {
    this.point = null;
  }
}

/** Eyedropper: picks up the colour shown where it's lifted, then goes back to the tool before. */
class EyedropperTool {
  constructor(tools) {
    this.tools = tools;
  }

  options() {
    return colorWell(this.tools.color);
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      this.tools.color = value;
    });
  }

  begin(point) {
    this.point = point;
  }

  update(points) {
    this.point = points.at(-1) ?? this.point;
  }

  end() {
    const color = this.point && this.tools.window.colorAt(this.point);
    this.point = null;
    if (!color || color[3] === 0) return;
    this.tools.color = toHex(color[0], color[1], color[2]);
    this.tools.choose(this.tools.previous ?? "brush");
  }

  cancel() {
    this.point = null;
  }
}

// ------------------------------------------------------------ Drafts

const number = (value) => Math.round(value * 100) / 100;
const rectOf = (a, b) => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) });
const polyline = (points) => points.map((p, i) => `${i ? "L" : "M"}${number(p.x)} ${number(p.y)}`).join("");

/** Whether a drag from `a` to `b` is short enough on screen to be a tap. */
function isTap(window, a, b) {
  return Math.hypot(b.x - a.x, b.y - a.y) * window.zoom < 4;
}

/** A handle's square, a fixed size on screen. */
function handle(window, point) {
  const side = 8 / window.zoom;
  return `<rect class="app__draft-handle" x="${number(point.x - side / 2)}" y="${number(point.y - side / 2)}" width="${number(side)}" height="${number(side)}"/>`;
}

/** The points of a regular polygon or a star inside `rect`, as ShapeSpec draws them. */
function shapePoints(rect, sides, star) {
  const cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2;
  const count = star ? sides * 2 : sides;
  return Array.from({ length: count }, (_, i) => {
    const angle = -Math.PI / 2 + (i * Math.PI * 2) / count;
    const r = star && i % 2 ? 0.45 : 1;
    return { x: cx + Math.cos(angle) * (rect.width / 2) * r, y: cy + Math.sin(angle) * (rect.height / 2) * r };
  });
}

// ------------------------------------------------------------ Arranging

/** Move: drags the selected layer; a tap picks the layer under it. */
class MoveTool {
  constructor(tools) {
    this.tools = tools;
  }

  options() {
    return "";
  }

  bind() {}

  begin(point) {
    this.start = point;
    this.last = point;
  }

  update(points) {
    if (!this.start) return;
    this.last = points.at(-1);
    this.tools.window.canvasView.moveActive(Math.round(this.last.x - this.start.x), Math.round(this.last.y - this.start.y));
  }

  async end() {
    const { start, last: end } = this;
    this.start = null;
    if (!start) return;
    const window = this.tools.window;
    if (isTap(window, start, end)) {
      window.canvasView.moveActive(0, 0);
      const { response } = await window.engine.call("hit", { doc: window.doc, x: start.x, y: start.y });
      if (response.layer && response.layer !== window.selected) window.select(response.layer);
      return;
    }
    window.edit("move", { dx: Math.round(end.x - start.x), dy: Math.round(end.y - start.y) });
  }

  cancel() {
    this.start = null;
    this.tools.window.canvasView.moveActive(0, 0);
  }
}

/** Select: draws a rectangle, ellipse or lasso, or picks a run of colour, and adds it to the selection as the mode says. */
class SelectTool {
  constructor(tools) {
    this.tools = tools;
    this.kind = "rectangle";
    this.mode = "replace";
    this.tolerance = 0.12;
  }

  options() {
    return choice("kind", "Tool.Select", [["rectangle", "Select.Rectangle"], ["ellipse", "Select.Ellipse"], ["lasso", "Select.Lasso"], ["magic", "Select.Magic"]], this.kind)
      + choice("mode", "Select.Mode", [["replace", "Select.Mode.Replace"], ["add", "Select.Mode.Add"], ["subtract", "Select.Mode.Subtract"], ["intersect", "Select.Mode.Intersect"]], this.mode)
      + (this.kind === "magic" ? slider("tolerance", "Options.Tolerance", 0, 100, Math.round(this.tolerance * 100), "%") : "")
      + action("all", "Select.All") + action("none", "Select.Deselect") + action("invert", "Select.Invert");
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "tolerance") this.tolerance = value / 100;
      else this[key] = value;
      if (key === "kind") this.tools.renderOptions();
    });
    bindActions(element, (name) => this.tools.window.selectArea({ shape: name }));
  }

  begin(point, event) {
    // Shift adds and Option takes away, as on a Mac.
    this.drawMode = event.shiftKey ? "add" : event.altKey ? "subtract" : this.mode;
    this.points = [point];
  }

  update(points) {
    if (!this.points) return;
    if (this.kind === "lasso") this.points.push(...points);
    else this.points[1] = points.at(-1);
    this.show();
  }

  show() {
    const [a, b = a] = this.points;
    const r = rectOf(a, b);
    const outline = this.kind === "lasso" ? `<path d="${polyline(this.points)}Z" class="app__ants-dark"/>`
      : this.kind === "ellipse" ? `<ellipse cx="${number(r.x + r.width / 2)}" cy="${number(r.y + r.height / 2)}" rx="${number(r.width / 2)}" ry="${number(r.height / 2)}" class="app__ants-dark"/>`
      : `<rect x="${number(r.x)}" y="${number(r.y)}" width="${number(r.width)}" height="${number(r.height)}" class="app__ants-dark"/>`;
    this.tools.window.draft(outline.replace("app__ants-dark", "app__ants-light") + outline);
  }

  end() {
    const points = this.points;
    this.points = null;
    if (!points) return;
    const window = this.tools.window;
    window.draft();
    const a = points[0], b = points.at(-1);
    if (this.kind === "magic") {
      window.selectArea({ shape: "magic", x: a.x, y: a.y, tolerance: this.tolerance, mode: this.drawMode });
    } else if (isTap(window, a, b) && this.kind !== "lasso" || points.length < 3 && this.kind === "lasso") {
      if (this.drawMode === "replace") window.selectArea({ shape: "none" });
    } else if (this.kind === "lasso") {
      window.selectArea({ shape: "lasso", points: points.flatMap((p) => [p.x, p.y]), mode: this.drawMode });
    } else {
      const r = rectOf(a, b);
      window.selectArea({ shape: this.kind, rect: [r.x, r.y, r.width, r.height], mode: this.drawMode });
    }
  }

  cancel() {
    this.points = null;
    this.tools.window.draft();
  }
}

/** Crop: drags out the part to keep, or moves it from inside; Apply or Return crops to it. */
class CropTool {
  constructor(tools) {
    this.tools = tools;
    this.rect = null;
  }

  options() {
    return action("apply", "Options.CropApply") + action("reset", "Options.CropReset");
  }

  bind(element) {
    bindActions(element, (name) => (name === "apply" ? this.apply() : this.reset()));
  }

  enter() {
    this.show();
  }

  leave() {
    this.rect = null;
    this.tools.window.draft();
  }

  get canvas() {
    const { width, height } = this.tools.window.info;
    return { x: 0, y: 0, width, height };
  }

  clamp(r) {
    const c = this.canvas;
    const x = Math.max(0, Math.min(r.x, c.width)), y = Math.max(0, Math.min(r.y, c.height));
    return { x, y, width: Math.min(r.x + r.width, c.width) - x, height: Math.min(r.y + r.height, c.height) - y };
  }

  begin(point) {
    const r = this.rect;
    const inside = r && point.x > r.x && point.x < r.x + r.width && point.y > r.y && point.y < r.y + r.height;
    this.drag = { start: point, moving: inside, origin: r };
  }

  update(points) {
    if (!this.drag) return;
    const p = points.at(-1), { start, moving, origin } = this.drag;
    if (moving) {
      const c = this.canvas;
      const x = Math.max(0, Math.min(origin.x + p.x - start.x, c.width - origin.width));
      const y = Math.max(0, Math.min(origin.y + p.y - start.y, c.height - origin.height));
      this.rect = { ...origin, x, y };
    } else {
      this.rect = this.clamp(rectOf(start, p));
    }
    this.show();
  }

  end() {
    const drag = this.drag;
    this.drag = null;
    if (drag && !drag.moving && (!this.rect || this.rect.width < 1 || this.rect.height < 1)) this.reset();
  }

  cancel() {
    if (this.drag) this.rect = this.drag.origin;
    this.drag = null;
    this.show();
  }

  show() {
    const r = this.rect, c = this.canvas;
    if (!r || !this.tools.window.info) {
      this.tools.window.draft();
      return;
    }
    const thirds = [1, 2].map((n) => `M${number(r.x + (r.width * n) / 3)} ${number(r.y)}v${number(r.height)}M${number(r.x)} ${number(r.y + (r.height * n) / 3)}h${number(r.width)}`).join("");
    const corners = [[r.x, r.y], [r.x + r.width, r.y], [r.x + r.width, r.y + r.height], [r.x, r.y + r.height]];
    this.tools.window.draft(
      `<path class="app__draft-shade" d="M0 0H${c.width}V${c.height}H0Z M${number(r.x)} ${number(r.y)}h${number(r.width)}v${number(r.height)}h${number(-r.width)}Z"/>`
      + `<path class="app__draft-line" d="${thirds}" opacity="0.5"/>`
      + `<rect class="app__draft-line" x="${number(r.x)}" y="${number(r.y)}" width="${number(r.width)}" height="${number(r.height)}"/>`
      + corners.map(([x, y]) => handle(this.tools.window, { x, y })).join(""),
    );
  }

  async apply() {
    const r = this.rect;
    if (!r || r.width < 1 || r.height < 1) return;
    this.rect = null;
    this.tools.window.draft();
    await this.tools.window.edit("crop", { rect: [r.x, r.y, r.width, r.height] }, { all: true });
  }

  reset() {
    this.rect = null;
    this.show();
  }

  key(event) {
    if (event.key === "Enter" && this.rect) {
      this.apply();
      return true;
    }
    if (event.key === "Escape" && this.rect) {
      this.reset();
      return true;
    }
    return false;
  }
}

// ------------------------------------------------------------ Bending

/** The unit square onto `p`'s four corners, keeping straight lines straight (WarpShape.projective). */
function projective(p, u, v) {
  const sx = p[0].x - p[1].x + p[2].x - p[3].x, sy = p[0].y - p[1].y + p[2].y - p[3].y;
  let g = 0, h = 0;
  if (Math.abs(sx) > 1e-9 || Math.abs(sy) > 1e-9) {
    const dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x, dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y;
    const denominator = dx1 * dy2 - dx2 * dy1;
    if (Math.abs(denominator) > 1e-12) {
      g = (sx * dy2 - dx2 * sy) / denominator;
      h = (dx1 * sy - sx * dy1) / denominator;
    }
  }
  const a = p[1].x - p[0].x + g * p[1].x, b = p[3].x - p[0].x + h * p[3].x, c = p[0].x;
  const d = p[1].y - p[0].y + g * p[1].y, e = p[3].y - p[0].y + h * p[3].y, f = p[0].y;
  const w = g * u + h * v + 1;
  return { x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w };
}

function cylinderDepth(points) {
  const corners = points.slice(0, 4), target = points[4];
  const distance = (v) => {
    const point = projective(corners, 0.5, v);
    return Math.hypot(point.x - target.x, point.y - target.y);
  };
  let low = -2, high = 2;
  const ratio = (Math.sqrt(5) - 1) / 2;
  for (let i = 0; i < 60; i++) {
    const a = high - (high - low) * ratio, b = low + (high - low) * ratio;
    if (distance(a) < distance(b)) high = b;
    else low = a;
  }
  return (low + high) / 2;
}

/** Where (u, v) of the layer lands, for the shape the handles make: 4 corners, 5 for a cylinder, 16 for a warp. */
function warpPoint(points, u, v) {
  if (points.length === 16) {
    const bernstein = (t) => [(1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3];
    const bu = bernstein(u), bv = bernstein(v);
    let x = 0, y = 0;
    for (let row = 0; row < 4; row++) {
      for (let column = 0; column < 4; column++) {
        x += points[row * 4 + column].x * bv[row] * bu[column];
        y += points[row * 4 + column].y * bv[row] * bu[column];
      }
    }
    return { x, y };
  }
  if (points.length === 5) {
    const angle = (u - 0.5) * Math.PI;
    return projective(points.slice(0, 4), 0.5 + Math.sin(angle) / 2, v + cylinderDepth(points) * Math.cos(angle));
  }
  return projective(points, u, v);
}

const TRANSFORM_MODES = [["distort", "Transform.Distort"], ["warp", "Transform.Warp"], ["cylinder", "Transform.Cylinder"]];

/** Transform: drags the active layer's corners in perspective, a grid over it as a sheet, or round a cylinder. */
class TransformTool {
  constructor(tools) {
    this.tools = tools;
    this.mode = "distort";
    this.draft = null;
    this.preview = null;
    this.drawing = null;
    this.waiting = false;
  }

  get window() {
    return this.tools.window;
  }

  get isChanged() {
    const draft = this.draft;
    return Boolean(draft) && (draft.points.length === 5 || draft.points.some((p, i) => Math.abs(p.x - draft.original[i].x) > 0.01 || Math.abs(p.y - draft.original[i].y) > 0.01));
  }

  options() {
    const changed = this.isChanged;
    const disabled = (button) => (changed ? button : button.replace("<button", "<button disabled"));
    return TRANSFORM_MODES.map(([id, label]) => action(id, label, this.mode === id)).join("")
      + disabled(action("reset", "Transform.Reset")) + disabled(action("apply", "Transform.Apply"));
  }

  bind(element) {
    bindActions(element, (name) => {
      if (name === "apply") this.apply();
      else if (name === "reset") this.reset();
      else this.setMode(name);
    });
  }

  enter() {
    this.load();
  }

  leave() {
    this.draft = null;
    this.clearPreview();
    this.window.draft();
  }

  changed() {
    if (this.draft && this.draft.layer === this.window.selected && this.isChanged) return;
    this.load();
  }

  async load(points = null) {
    const window = this.window;
    const layer = window.selected, row = window.selectedRow();
    if (window.doc === null || !layer || row?.kind !== "layer" || row.type === "adjustment") {
      this.leave();
      this.tools.renderOptions();
      return;
    }
    try {
      const { response } = await window.engine.call("transform", {
        doc: window.doc, layer, action: "handles", mode: this.mode, ...(points ? { points: points.flatMap((p) => [p.x, p.y]) } : {}),
      });
      const pairs = (flat) => flat.reduce((list, value, i) => (i % 2 ? list.at(-1).y = value : list.push({ x: value, y: 0 }), list), []);
      this.draft = { layer, points: pairs(response.points), original: pairs(response.original) };
      if (!points) this.clearPreview();
      else this.requestPreview();
    } catch {
      this.draft = null;
    }
    this.show();
    this.tools.renderOptions();
  }

  setMode(mode) {
    if (mode === this.mode) return;
    this.mode = mode;
    this.load(this.isChanged ? this.draft.points : null);
  }

  /** Warp's eight handles round its box, which scale the grid from the opposite side. */
  resizeHandles() {
    if (this.draft?.points.length !== 16) return [];
    const box = this.bounds(this.draft.points), margin = 18 / this.window.zoom;
    const x = box.x - margin, y = box.y - margin, width = box.width + margin * 2, height = box.height + margin * 2;
    return [[-1, -1], [0, -1], [1, -1], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0]].map(([sx, sy]) => ({
      side: { x: sx, y: sy }, x: x + width / 2 + (sx * width) / 2, y: y + height / 2 + (sy * height) / 2,
    }));
  }

  bounds(points) {
    const xs = points.map((p) => p.x), ys = points.map((p) => p.y);
    const x = Math.min(...xs), y = Math.min(...ys);
    return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y };
  }

  /** In warp, a corner's neighbours go with it so its curves keep their shape. */
  moving(index) {
    if (this.draft.points.length !== 16) return [index];
    const row = Math.floor(index / 4), column = index % 4;
    if (!((row === 0 || row === 3) && (column === 0 || column === 3))) return [index];
    const nextRow = row === 0 ? 1 : 2, nextColumn = column === 0 ? 1 : 2;
    return [index, row * 4 + nextColumn, nextRow * 4 + column, nextRow * 4 + nextColumn];
  }

  begin(point) {
    const draft = this.draft;
    if (!draft || this.window.selectedRow()?.groupLocked) return;
    const reach = 30 / this.window.zoom;
    const distance = (p) => Math.hypot(p.x - point.x, p.y - point.y);
    const all = draft.points.map((origin, index) => ({ index, origin }));
    let nearest = -1;
    draft.points.forEach((p, i) => {
      if (nearest < 0 || distance(p) < distance(draft.points[nearest])) nearest = i;
    });
    const resize = this.resizeHandles().reduce((best, h) => (!best || distance(h) < distance(best) ? h : best), null);
    if (resize && distance(resize) <= reach && distance(resize) < distance(draft.points[nearest])) {
      this.drawing = { start: point, handles: all, resize: { side: resize.side, box: this.bounds(draft.points) } };
    } else if (nearest >= 0 && distance(draft.points[nearest]) <= reach) {
      this.drawing = { start: point, handles: this.moving(nearest).map((index) => ({ index, origin: draft.points[index] })) };
    } else {
      this.drawing = { start: point, handles: all };
    }
    this.drawing.depth = draft.points.length === 5 ? cylinderDepth(draft.points) : null;
  }

  update(points) {
    const drag = this.drawing, draft = this.draft;
    if (!drag || !draft) return;
    const p = points.at(-1), dx = p.x - drag.start.x, dy = p.y - drag.start.y;
    if (drag.resize) {
      const from = drag.resize.box, side = drag.resize.side;
      let { x, y, width, height } = from;
      if (side.x < 0) [x, width] = [Math.min(x + dx, from.x + from.width - 1), Math.max(width - dx, 1)];
      if (side.x > 0) width = Math.max(width + dx, 1);
      if (side.y < 0) [y, height] = [Math.min(y + dy, from.y + from.height - 1), Math.max(height - dy, 1)];
      if (side.y > 0) height = Math.max(height + dy, 1);
      draft.points = drag.handles.map(({ origin: o }) => ({
        x: from.width > 0 ? x + ((o.x - from.x) / from.width) * width : o.x + x - from.x,
        y: from.height > 0 ? y + ((o.y - from.y) / from.height) * height : o.y + y - from.y,
      }));
    } else {
      for (const { index, origin } of drag.handles) draft.points[index] = { x: origin.x + dx, y: origin.y + dy };
      // A cylinder's curve stays as deep while its corners move.
      if (drag.depth !== null && drag.handles.length === 1 && drag.handles[0].index < 4) {
        draft.points[4] = projective(draft.points.slice(0, 4), 0.5, drag.depth);
      }
    }
    this.show();
    this.requestPreview();
  }

  end() {
    if (!this.drawing) return;
    this.drawing = null;
    this.tools.renderOptions();
  }

  cancel() {
    const drag = this.drawing;
    this.drawing = null;
    if (!drag || !this.draft) return;
    for (const { index, origin } of drag.handles) this.draft.points[index] = origin;
    this.show();
    this.requestPreview();
  }

  /** The layer bent, worked out small by the engine; only the newest is kept. */
  async requestPreview() {
    if (this.waiting) {
      this.again = true;
      return;
    }
    const draft = this.draft, window = this.window;
    if (!draft) return;
    this.waiting = true;
    this.again = false;
    try {
      const { response, payload } = await window.engine.call("transform", {
        doc: window.doc, layer: draft.layer, action: "preview", mode: this.mode, maxSize: 900,
        points: draft.points.flatMap((p) => [p.x, p.y]),
      });
      if (this.draft === draft) {
        const canvas = document.createElement("canvas");
        canvas.width = response.width;
        canvas.height = response.height;
        canvas.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(payload.buffer, payload.byteOffset, payload.byteLength), response.width, response.height), 0, 0);
        this.preview = canvas.toDataURL();
        window.canvasView?.hideActive(true);
        this.show();
      }
    } catch {
      // The handles still show where it goes.
    } finally {
      this.waiting = false;
      if (this.again) this.requestPreview();
    }
  }

  clearPreview() {
    this.preview = null;
    this.again = false;
    this.window.canvasView?.hideActive(false);
  }

  show() {
    const draft = this.draft, window = this.window;
    if (!draft || !window.info) {
      window.draft();
      return;
    }
    const { width, height } = window.info;
    const steps = 24, fractions = draft.points.length === 16 ? [0, 1 / 3, 2 / 3, 1] : [0, 1];
    const lines = fractions.flatMap((f) => [
      Array.from({ length: steps + 1 }, (_, i) => warpPoint(draft.points, i / steps, f)),
      Array.from({ length: steps + 1 }, (_, i) => warpPoint(draft.points, f, i / steps)),
    ]);
    const image = this.preview ? `<image href="${this.preview}" x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="none"/>` : "";
    const guides = draft.points.length === 16
      ? [0, 1, 2, 3].map((r) => polyline(draft.points.slice(r * 4, r * 4 + 4))).join("") + [0, 1, 2, 3].map((c) => polyline([0, 1, 2, 3].map((r) => draft.points[r * 4 + c]))).join("")
      : "";
    window.draft(
      image
      + `<path class="app__draft-line" d="${lines.map(polyline).join("")}"/>`
      + (guides ? `<path class="app__draft-line" d="${guides}" opacity="0.35"/>` : "")
      + draft.points.map((p) => handle(window, p)).join("")
      + this.resizeHandles().map((p) => handle(window, p)).join(""),
    );
  }

  async apply() {
    const draft = this.draft;
    if (!draft || !this.isChanged) return;
    const done = await this.window.edit("transform", { layer: draft.layer, action: "apply", mode: this.mode, points: draft.points.flatMap((p) => [p.x, p.y]) });
    if (done) {
      this.draft = null;
      this.clearPreview();
      this.load();
    }
  }

  reset() {
    if (!this.draft) return;
    this.draft.points = this.draft.original.map((p) => ({ ...p }));
    this.clearPreview();
    this.show();
    this.tools.renderOptions();
  }

  key(event) {
    if (event.key === "Enter" && this.isChanged) {
      this.apply();
      return true;
    }
    if (event.key === "Escape" && this.isChanged) {
      this.reset();
      return true;
    }
    return false;
  }
}

// ------------------------------------------------------------ Painting along a line

const GRADIENT_KINDS = [["linear", "Gradient.Linear"], ["radial", "Gradient.Radial"], ["angular", "Gradient.Angular"], ["reflected", "Gradient.Reflected"], ["diamond", "Gradient.Diamond"]];

/** Gradient: drag a line along which the colour runs out, or to white, or black to white. */
class GradientTool {
  constructor(tools) {
    this.tools = tools;
    this.kind = "linear";
    this.preset = "fading";
    this.opacity = 1;
  }

  options() {
    return colorWell(this.tools.color)
      + choice("kind", "Gradient.Kind", GRADIENT_KINDS, this.kind)
      + choice("preset", "Gradient.Presets", [["fading", "Gradient.Preset.Fading"], ["toWhite", "Gradient.Preset.ToWhite"], ["blackToWhite", "Gradient.Preset.BlackToWhite"]], this.preset)
      + slider("opacity", "Options.Opacity", 1, 100, Math.round(this.opacity * 100), "%");
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "color") this.tools.color = value;
      else if (key === "opacity") this.opacity = value / 100;
      else this[key] = value;
    });
  }

  get stops() {
    const color = hexToColor(this.tools.color);
    const [from, to] = {
      fading: [color, [...color.slice(0, 3), 0]],
      toWhite: [color, [1, 1, 1, 1]],
      blackToWhite: [[0, 0, 0, 1], [1, 1, 1, 1]],
    }[this.preset];
    return [0, ...from, 1, ...to];
  }

  begin(point) {
    this.line = [point, point];
  }

  update(points) {
    if (!this.line) return;
    this.line[1] = points.at(-1);
    const [a, b] = this.line, window = this.tools.window;
    window.draft(`<path class="app__draft-line" d="M${number(a.x)} ${number(a.y)}L${number(b.x)} ${number(b.y)}"/>` + handle(window, a) + handle(window, b));
  }

  end() {
    const line = this.line;
    this.line = null;
    const window = this.tools.window;
    window.draft();
    if (!line || isTap(window, line[0], line[1])) return;
    window.edit("gradient", { line: [line[0].x, line[0].y, line[1].x, line[1].y], gradient: this.kind, stops: this.stops, opacity: this.opacity });
  }

  cancel() {
    this.line = null;
    this.tools.window.draft();
  }
}

// ------------------------------------------------------------ Adding

const SHAPES = [
  ["rectangle", "Shape.Rectangle"], ["roundedRectangle", "Shape.RoundedRectangle"], ["ellipse", "Shape.Ellipse"],
  ["polygon", "Shape.Polygon"], ["star", "Shape.Star"], ["line", "Shape.Line"], ["arrow", "Shape.Arrow"],
];

/** Shape: drags out a shape, which becomes a vector layer of its own. */
class ShapeTool {
  constructor(tools) {
    this.tools = tools;
    this.kind = "rectangle";
    this.filled = true;
    this.lineWidth = 8;
  }

  get sides() {
    return this.kind === "star" ? 5 : 6;
  }

  get isLine() {
    return this.kind === "line" || this.kind === "arrow";
  }

  options() {
    return colorWell(this.tools.color)
      + choice("kind", "Shape.Kind", SHAPES, this.kind)
      + (this.isLine ? "" : toggle("filled", "Options.ShapeFilled", this.filled))
      + (this.isLine || !this.filled ? slider("lineWidth", "Options.LineWidth", 1, 200, this.lineWidth) : "");
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "color") this.tools.color = value;
      else this[key] = value;
      if (key === "kind" || key === "filled") this.tools.renderOptions();
    });
  }

  begin(point) {
    this.line = [point, point];
  }

  update(points) {
    if (!this.line) return;
    this.line[1] = points.at(-1);
    this.show();
  }

  show() {
    const [a, b] = this.line, r = rectOf(a, b);
    const filled = this.filled && !this.isLine;
    const paint = filled ? `fill="${this.tools.color}" stroke="none"` : `fill="none" stroke="${this.tools.color}" stroke-width="${this.lineWidth}" stroke-linecap="round" stroke-linejoin="round" style="vector-effect:none"`;
    let shape;
    switch (this.kind) {
      case "ellipse":
        shape = `<ellipse cx="${number(r.x + r.width / 2)}" cy="${number(r.y + r.height / 2)}" rx="${number(r.width / 2)}" ry="${number(r.height / 2)}" ${paint}/>`;
        break;
      case "polygon":
      case "star":
        shape = `<path d="${polyline(shapePoints(r, this.sides, this.kind === "star"))}Z" ${paint}/>`;
        break;
      case "line":
      case "arrow": {
        const angle = Math.atan2(b.y - a.y, b.x - a.x), head = this.lineWidth * 3;
        const wing = (turn) => ({ x: b.x - Math.cos(angle + turn) * head, y: b.y - Math.sin(angle + turn) * head });
        const tip = this.kind === "arrow" ? `M${polyline([wing(0.5), b, wing(-0.5)]).slice(1)}` : "";
        shape = `<path d="M${number(a.x)} ${number(a.y)}L${number(b.x)} ${number(b.y)}${tip}" ${paint}/>`;
        break;
      }
      default: {
        const radius = this.kind === "roundedRectangle" ? Math.min(24, r.width / 2, r.height / 2) : 0;
        shape = `<rect x="${number(r.x)}" y="${number(r.y)}" width="${number(r.width)}" height="${number(r.height)}" rx="${number(radius)}" ${paint}/>`;
      }
    }
    this.tools.window.draft(`<g opacity="0.8">${shape}</g>`);
  }

  async end() {
    const line = this.line;
    this.line = null;
    const window = this.tools.window;
    if (!line || isTap(window, line[0], line[1])) {
      window.draft();
      return;
    }
    await window.edit("shape", {
      shape: this.kind, line: [line[0].x, line[0].y, line[1].x, line[1].y], filled: this.filled,
      lineWidth: this.lineWidth, color: hexToColor(this.tools.color), sides: this.sides,
    }, { all: true });
    window.draft();
  }

  cancel() {
    this.line = null;
    this.tools.window.draft();
  }
}

/** Text: a tap on a text layer changes its words; anywhere else on the picture adds new text. */
class TextTool {
  constructor(tools) {
    this.tools = tools;
  }

  options() {
    return colorWell(this.tools.color) + `<span class="ds-caption app__option-hint">${escapeHTML(t("Options.TapToAddText"))}</span>`;
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      this.tools.color = value;
    });
  }

  begin(point) {
    this.start = point;
    this.last = point;
  }

  update(points) {
    this.last = points.at(-1) ?? this.last;
  }

  async end() {
    const { start, last: end } = this;
    this.start = null;
    const window = this.tools.window;
    if (!start || !isTap(window, start, end)) return;
    const { response: hit } = await window.engine.call("hit", { doc: window.doc, x: start.x, y: start.y, text: true });
    if (hit.layer) {
      window.select(hit.layer);
      const string = await window.askText(hit.string);
      if (string !== null && string !== hit.string) window.edit("text", { layer: hit.layer, edit: true, string }, { all: true });
      return;
    }
    if (start.x < 0 || start.y < 0 || start.x > window.info.width || start.y > window.info.height) return;
    const string = await window.askText("");
    if (string?.trim()) window.edit("text", { x: start.x, y: start.y, string, color: hexToColor(this.tools.color) }, { all: true });
  }

  cancel() {
    this.start = null;
  }
}

// ------------------------------------------------------------ Paths

/** How close, on screen, a touch has to be to grab a point. */
const VECTOR_REACH = 22;

/** A path's outline as SVG path data; its points are { x, y, in, out } in the picture's pixels. */
function pathData(nodes, closed) {
  if (!nodes.length) return "";
  const pair = (p) => `${number(p[0] ?? p.x)} ${number(p[1] ?? p.y)}`;
  const segment = (a, b) => `C${pair(a.out ?? a)} ${pair(b.in ?? b)} ${pair(b)}`;
  let d = `M${pair(nodes[0])}`;
  for (let i = 1; i < nodes.length; i++) d += segment(nodes[i - 1], nodes[i]);
  if (closed && nodes.length > 1) d += `${segment(nodes.at(-1), nodes[0])}Z`;
  return d;
}

/** A point's handles: lines out to dots. */
function controlHandles(window, node) {
  const radius = 4 / window.zoom;
  return ["in", "out"].filter((key) => node[key]).map((key) => {
    const [x, y] = node[key];
    return `<path class="app__draft-line" d="M${number(node.x)} ${number(node.y)}L${number(x)} ${number(y)}"/><circle class="app__draft-handle" cx="${number(x)}" cy="${number(y)}" r="${number(radius)}"/>`;
  }).join("");
}

function nodeMark(window, node, picked) {
  const side = 8 / window.zoom;
  return `<rect class="app__draft-handle${picked ? " is-picked" : ""}" x="${number(node.x - side / 2)}" y="${number(node.y - side / 2)}" width="${number(side)}" height="${number(side)}"/>`;
}

/** Pen: a tap places a corner, a drag pulls out a curve; back on the first point closes the shape. */
class PenTool {
  constructor(tools) {
    this.tools = tools;
    this.filled = false;
    this.lineWidth = 4;
    this.addsToLayer = false;
    this.path = null;
    this.drag = null;
    this.saving = Promise.resolve();
  }

  get window() {
    return this.tools.window;
  }

  options() {
    return colorWell(this.tools.color)
      + toggle("filled", "Options.ShapeFilled", this.filled)
      + slider("lineWidth", "Options.LineWidth", 1, 200, this.lineWidth)
      + toggle("addsToLayer", "Options.PenAddsToLayer", this.addsToLayer)
      + (this.path ? action("finish", "Options.FinishPath") : `<span class="ds-caption app__option-hint">${escapeHTML(t("Options.TapToStartPath"))}</span>`);
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "color") this.tools.color = value;
      else this[key] = value;
    });
    bindActions(element, () => this.finish());
  }

  leave() {
    this.finish();
  }

  begin(point) {
    const window = this.window, reach = VECTOR_REACH / window.zoom;
    const path = this.path;
    if (path) {
      const first = path.nodes[0];
      if (path.nodes.length > 1 && Math.hypot(first.x - point.x, first.y - point.y) < reach) {
        path.closed = true;
        this.save();
        this.finish();
        return;
      }
      path.nodes.push({ x: point.x, y: point.y, in: null, out: null, smooth: false });
    } else {
      const row = window.selectedRow();
      const color = hexToColor(this.tools.color);
      this.path = {
        layer: this.addsToLayer && row?.type === "vector" && !row.locked && !row.groupLocked ? row.id : null,
        index: null, closed: false, fill: this.filled ? color : null, stroke: color, strokeWidth: this.lineWidth,
        nodes: [{ x: point.x, y: point.y, in: null, out: null, smooth: false }],
      };
      this.tools.renderOptions();
    }
    this.drag = { start: point };
    this.show();
  }

  /** Dragging after placing a point pulls out its handles, making a curve; a short wobble keeps a corner. */
  update(points) {
    if (!this.drag || !this.path) return;
    const p = points.at(-1), start = this.drag.start;
    if (Math.hypot(p.x - start.x, p.y - start.y) <= VECTOR_REACH / this.window.zoom / 4) return;
    const node = this.path.nodes.at(-1);
    node.out = [p.x, p.y];
    node.in = [2 * node.x - p.x, 2 * node.y - p.y];
    node.smooth = true;
    this.show();
  }

  end() {
    if (!this.drag) return;
    this.drag = null;
    if (this.path?.nodes.length > 1) this.save();
    else this.show();
  }

  cancel() {
    this.drag = null;
    this.show();
  }

  /** Sends the path as it is: a layer of its own the first time, unless it joins the vector layer in hand. */
  save() {
    const path = this.path;
    const snapshot = { closed: path.closed, fill: path.fill, stroke: path.stroke, strokeWidth: path.strokeWidth, nodes: path.nodes.map((n) => ({ ...n })) };
    this.saving = this.saving.then(async () => {
      const window = this.window;
      if (!path.layer) {
        const before = window.selected;
        await window.edit("vector", { action: "add", paths: [snapshot] }, { all: true });
        if (window.selected !== before) {
          path.layer = window.selected;
          path.index = 0;
        }
        return;
      }
      const { response } = await window.engine.call("paths", { doc: window.doc, layer: path.layer });
      const paths = response.paths;
      if (path.index === null) path.index = paths.length;
      paths[path.index] = { ...snapshot, index: path.index < paths.length ? path.index : undefined };
      await window.edit("vector", { layer: path.layer, action: "set", paths });
    }).finally(() => this.path === path && this.show());
  }

  finish() {
    if (!this.path) return;
    this.path = null;
    this.drag = null;
    this.window.draft();
    this.tools.renderOptions();
  }

  show() {
    const path = this.path, window = this.window;
    if (!path) {
      window.draft();
      return;
    }
    const last = path.nodes.at(-1);
    window.draft(
      `<path class="app__draft-line" d="${pathData(path.nodes, path.closed)}"/>`
      + path.nodes.map((node) => nodeMark(window, node, node === last)).join("")
      + controlHandles(window, last),
    );
  }

  key(event) {
    if ((event.key === "Enter" || event.key === "Escape") && this.path) {
      this.finish();
      return true;
    }
    return false;
  }
}

const PATTERNS = ["dots", "stripes", "checker", "grid", "diagonal", "waves"].map((id) => [id, `Pattern.${id[0].toUpperCase()}${id.slice(1)}`]);

/** Roughly how big a region's path data is: its box's area. */
function boxArea(data) {
  const numbers = data.match(/-?[\d.]+(?:e-?\d+)?/g)?.map(Number) ?? [];
  const xs = numbers.filter((_, i) => i % 2 === 0), ys = numbers.filter((_, i) => i % 2 === 1);
  return (Math.max(...xs) - Math.min(...xs)) * (Math.max(...ys) - Math.min(...ys));
}

const COMBINE = [["unite", "Vector.Unite"], ["subtract", "Vector.Subtract"], ["intersect", "Vector.Intersect"], ["exclude", "Vector.Exclude"]];

/** Nodes: moves a vector layer's points and their handles, and changes its paths' colours. */
class NodesTool {
  constructor(tools) {
    this.tools = tools;
    this.paths = null;
    this.layer = null;
    this.picked = [];
    this.multiple = false;
    this.drag = null;
  }

  get window() {
    return this.tools.window;
  }

  /** The picked point, if any: { path, node }. */
  get main() {
    const ref = this.picked[0];
    return ref && this.paths?.[ref.path]?.nodes[ref.node] ? ref : null;
  }

  /** The path the colours change: the picked point's, or the first. */
  get styled() {
    return this.paths?.[this.main?.path ?? 0] ?? null;
  }

  options() {
    if (this.builder) {
      const none = this.builder.picked.size === 0;
      const off = (button) => (none ? button.replace("<button", "<button disabled") : button);
      return action("cancelBuilder", "Common.Cancel") + off(action("deleteFaces", "ShapeBuilder.Delete")) + off(action("mergeFaces", "ShapeBuilder.Merge"))
        + `<span class="ds-caption app__option-hint">${escapeHTML(t("ShapeBuilder.Hint"))}</span>`;
    }
    const path = this.styled;
    if (!path) return `<span class="ds-caption app__option-hint">${escapeHTML(t("Options.PickVectorLayer"))}</span>`;
    const main = this.main;
    const closed = this.paths.filter((p) => p.closed && p.nodes.length > 2).length;
    const color = path.text?.color ?? path.fill ?? path.stroke;
    const live = path.live;
    let html = colorWell(color ? toHex(...color.slice(0, 3).map((v) => Math.round(v * 255))) : this.tools.color)
      + action("fill", "Options.Fill", path.fill !== null);
    if (path.fill) {
      html += action("gradient", "Options.GradientFill", path.gradient !== null);
      html += path.gradient
        ? choice("gradientKind", "Gradient.Kind", GRADIENT_KINDS, path.gradient.kind) + slider("angle", "LayerFilters.Angle", -180, 180, Math.round(path.gradient.angle), "°")
        : choice("pattern", "Options.PatternFill", [["", "Options.NoPattern"], ...PATTERNS], path.pattern ?? "");
    }
    html += action("stroke", "Options.Stroke", path.stroke !== null);
    if (path.stroke) html += slider("lineWidth", "Options.LineWidth", 1, 200, Math.round(path.strokeWidth)) + action("strokeStyle", "Stroke.Style");
    html += action("pathOperations", "Vector.PathOperations");
    if (closed >= 2) html += action("combine", "Vector.Combine");
    if (live?.kind === "roundedRectangle") html += slider("cornerRadius", "Shape.CornerRadius", 0, 400, Math.round(live.cornerRadius), " px");
    if (live?.kind === "polygon" || live?.kind === "star") html += slider("sides", live.kind === "star" ? "Shape.Points" : "Shape.Sides", 3, 16, live.sides);
    if (live?.kind === "star") html += slider("innerRatio", "Shape.InnerRadius", 10, 95, Math.round(live.innerRatio * 100), "%");
    html += action("multiple", "Options.SelectMultiplePoints", this.multiple) + action("all", "Options.SelectAllPoints");
    if (main) {
      html += action("smooth", path.nodes[main.node].smooth ? "Options.MakeCorner" : "Options.MakeSmooth")
        + action("insert", "Options.AddPoint") + action("delete", "Options.DeletePoint")
        + action("pathText", "Options.PathText", path.text !== null)
        + action("close", path.closed ? "Options.OpenPath" : "Options.ClosePath");
      if (path.text) {
        html += slider("fontSize", "Text.Size", 4, 400, Math.round(path.text.fontSize), " px")
          + slider("start", "Options.PathText.Start", 0, 100, Math.round(path.text.start * 100), "%")
          + toggle("bold", "Text.Bold", path.text.bold) + action("removeText", "Options.PathText.Remove");
      }
    }
    return html;
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      switch (key) {
        case "color":
          this.tools.color = value;
          return this.restyle({ paint: hexToColor(value) }, { later: true });
        case "lineWidth":
          return this.style((path) => {
            path.strokeWidth = value;
          }, { later: true });
        case "gradientKind": return this.restyle({ gradient: value });
        case "angle": return this.restyle({ angle: value }, { later: true });
        case "pattern": return this.restyle({ pattern: value || null });
        case "cornerRadius": return this.restyle({ live: { cornerRadius: value } }, { later: true });
        case "sides": return this.restyle({ live: { sides: value } }, { later: true });
        case "innerRatio": return this.restyle({ live: { innerRatio: value / 100 } }, { later: true });
        case "fontSize": return this.restyle({ text: { fontSize: value } }, { later: true });
        case "start": return this.restyle({ text: { start: value / 100 } }, { later: true });
        case "bold": return this.restyle({ text: { bold: value } });
      }
    });
    bindActions(element, (name, button) => this.perform(name, button));
  }

  perform(name, button) {
    const color = hexToColor(this.tools.color);
    switch (name) {
      case "fill":
        return this.style((path) => {
          path.fill = path.fill ? null : color;
        });
      case "stroke":
        return this.style((path) => {
          path.stroke = path.stroke ? null : color;
        });
      case "gradient": {
        const on = this.styled.gradient === null;
        return this.restyle(on ? { gradient: "linear", stops: this.tools.tools.gradient.stops } : { gradient: null });
      }
      case "strokeStyle":
        return openMenu(this.strokeStyleItems(), button);
      case "pathOperations":
        return openMenu([
          { label: t("Vector.OffsetPath"), action: () => this.askOffset() },
          { label: t("Vector.OutlineStroke"), disabled: !this.styled.stroke, action: () => this.operate({ action: "outline" }) },
        ], button);
      case "combine":
        return openMenu([
          ...COMBINE.map(([id, label]) => ({ label: t(label), action: () => this.operate({ action: "combine", operation: id }) })),
          { separator: true },
          { label: t("ShapeBuilder.Title"), action: () => this.startBuilder() },
        ], button);
      case "pathText":
        return this.askPathText();
      case "removeText":
        return this.restyle({ text: null });
      case "multiple":
        this.multiple = !this.multiple;
        return this.tools.renderOptions();
      case "all":
        this.picked = this.paths.flatMap((path, p) => path.nodes.map((_, n) => ({ path: p, node: n })));
        this.show();
        return this.tools.renderOptions();
      case "smooth":
        return this.toggleSmooth();
      case "insert":
        return this.insert();
      case "delete":
        return this.deletePicked();
      case "close": {
        const path = this.paths[this.main.path];
        path.closed = !path.closed;
        return this.save();
      }
      case "cancelBuilder":
        this.builder = null;
        this.show();
        return this.tools.renderOptions();
      case "deleteFaces":
      case "mergeFaces": {
        const picked = [...this.builder.picked];
        this.builder = null;
        this.tools.renderOptions();
        return this.operate({ action: "build", picked, deleting: name === "deleteFaces" });
      }
    }
  }

  /** The stroke's dashes, ends, corners, alignment, arrowheads and width profile, as the Apple apps' menu has them. */
  strokeStyleItems() {
    const path = this.styled, style = path.strokeStyle;
    const uniform = style.profile === "uniform";
    const submenu = (label, key, cases, prefix) => ({
      label: t(label),
      submenu: cases.map(([id, name]) => ({ label: t(`${prefix}.${name}`), checked: style[key] === id, action: () => this.restyle({ strokeStyle: { [key]: id } }) })),
    });
    const arrows = [["none", "None"], ["triangle", "Triangle"], ["open", "Open"], ["circle", "Circle"], ["bar", "Bar"]];
    return [
      ...(uniform ? [submenu("Stroke.Dash", "dash", [["solid", "Solid"], ["dashed", "Dashed"], ["dotted", "Dotted"]], "Stroke.Dash")] : []),
      submenu("Stroke.Profile", "profile", [["uniform", "Uniform"], ["taper", "Taper"], ["taperStart", "TaperStart"], ["taperEnd", "TaperEnd"], ["bulge", "Bulge"]], "Stroke.Profile"),
      ...(uniform ? [
        submenu("Stroke.Cap", "cap", [["round", "Round"], ["butt", "Butt"], ["square", "Square"]], "Stroke.Cap"),
        submenu("Stroke.Join", "join", [["round", "Round"], ["miter", "Miter"], ["bevel", "Bevel"]], "Stroke.Join"),
      ] : []),
      ...(path.closed
        ? (uniform ? [submenu("Stroke.Align", "alignment", [["center", "Center"], ["inside", "Inside"], ["outside", "Outside"]], "Stroke.Align")] : [])
        : [submenu("Stroke.StartArrow", "startArrow", arrows, "Stroke.Arrow"), submenu("Stroke.EndArrow", "endArrow", arrows, "Stroke.Arrow")]),
    ];
  }

  /** Changes the look of the picked point's path, or every path, in the engine. */
  async restyle(changes, { later = false } = {}) {
    if (!this.paths || this.locked) return;
    const send = () => this.operate({ action: "style", color: hexToColor(this.tools.color), ...changes }, { quiet: later });
    clearTimeout(this.styling);
    if (later) this.styling = setTimeout(send, 200);
    else return send();
  }

  /** A path operation on the picked point's path, or every path; the points picked go. */
  async operate(request, { quiet = false } = {}) {
    if (!this.layer) return;
    const path = request.action === "style" || request.action === "offset" || request.action === "outline" ? this.main?.path : undefined;
    if (request.action !== "style") this.picked = [];
    this.quiet = quiet;
    try {
      await this.window.edit("vector", { layer: this.layer, ...(path === undefined ? {} : { path }), ...request });
    } finally {
      this.quiet = false;
    }
  }

  async askOffset() {
    const { width, height } = this.window.info;
    const answer = await this.window.ask({
      title: t("Vector.OffsetPath"), message: t("Vector.OffsetPath.Message"), placeholder: t("Vector.OffsetPath.Distance"),
      value: String(Math.max(4, Math.round(Math.max(width, height) / 200))), type: "number",
    });
    const distance = Number(answer?.replace(",", "."));
    if (answer !== null && Number.isFinite(distance) && distance !== 0) this.operate({ action: "offset", distance });
  }

  async askPathText() {
    const path = this.styled;
    const answer = await this.window.ask({
      title: t("Options.PathText"), placeholder: t("Text.Placeholder"), confirm: t("Options.PathText.Apply"), value: path.text?.string ?? "",
    });
    if (answer !== null) this.restyle({ text: answer.trim() ? { string: answer } : null });
  }

  // ------------------------------------------------------------ Shape Builder

  async startBuilder() {
    const window = this.window;
    const { response } = await window.engine.call("paths", { doc: window.doc, layer: this.layer, faces: true });
    if (response.faces.length < 2) return;
    const [a, b, c, d, e, f] = response.transform;
    const det = a * d - b * c || 1;
    this.builder = {
      faces: response.faces.map((data) => ({ data, shape: new Path2D(data), area: boxArea(data) })),
      matrix: `matrix(${response.transform.join(" ")})`,
      toLocal: (p) => ({ x: (d * (p.x - e) - c * (p.y - f)) / det, y: (-b * (p.x - e) + a * (p.y - f)) / det }),
      picked: new Set(),
    };
    this.picked = [];
    this.show();
    this.tools.renderOptions();
  }

  /** The smallest region under a point, so small ones can be reached. */
  pickFace(point) {
    const builder = this.builder, local = builder.toLocal(point);
    const context = (this.hitContext ??= new OffscreenCanvas(1, 1).getContext("2d"));
    let best = -1;
    builder.faces.forEach((face, index) => {
      if (context.isPointInPath(face.shape, local.x, local.y, "evenodd") && (best < 0 || face.area < builder.faces[best].area)) best = index;
    });
    if (best < 0 || builder.picked.has(best)) return;
    builder.picked.add(best);
    this.show();
    this.tools.renderOptions();
  }

  enter() {
    this.load();
  }

  leave() {
    this.builder = null;
    this.paths = null;
    this.picked = [];
    this.window.draft();
  }

  changed() {
    if (!this.drag) this.load({ options: !this.quiet });
  }

  async load({ options = true } = {}) {
    const window = this.window, row = window.selectedRow();
    const layer = row?.type === "vector" ? row.id : null;
    if (layer !== this.layer) {
      this.picked = [];
      this.builder = null;
    }
    this.layer = layer;
    if (!layer || window.doc === null) {
      this.paths = null;
    } else {
      const { response } = await window.engine.call("paths", { doc: window.doc, layer });
      if (this.layer !== layer) return;
      this.paths = response.paths;
      this.locked = response.locked;
      this.picked = this.picked.filter((ref) => this.paths[ref.path]?.nodes[ref.node]);
    }
    this.show();
    if (options) this.tools.renderOptions();
  }

  /** Sends the paths; the engine's answer brings them back through load(). */
  async save({ render = true } = {}) {
    if (!this.layer) return;
    this.paths = this.paths.filter((path) => path.nodes.length > 1);
    this.picked = this.picked.filter((ref) => this.paths[ref.path]?.nodes[ref.node]);
    this.show();
    if (render) this.tools.renderOptions();
    this.quiet = !render;
    try {
      await this.window.edit("vector", { layer: this.layer, action: "set", paths: this.paths });
    } finally {
      this.quiet = false;
    }
  }

  /** Changes the picked point's path, or every path when none is picked. */
  style(change, { later = false } = {}) {
    if (!this.paths || this.locked) return;
    const only = this.main?.path;
    this.paths.forEach((path, index) => {
      if (only === undefined || only === index) change(path);
    });
    clearTimeout(this.styling);
    if (later) this.styling = setTimeout(() => this.save({ render: false }), 250);
    else this.save();
  }

  hit(point) {
    if (!this.paths || this.locked) return null;
    const reach = VECTOR_REACH / this.window.zoom;
    const near = (p) => Math.hypot(p[0] - point.x, p[1] - point.y) < reach;
    const main = this.main;
    if (main) {
      const node = this.paths[main.path].nodes[main.node];
      if (node.out && near(node.out)) return { kind: "out", ref: main };
      if (node.in && near(node.in)) return { kind: "in", ref: main };
    }
    for (const [p, path] of this.paths.entries()) {
      for (const [n, node] of path.nodes.entries()) {
        if (near([node.x, node.y])) return { kind: "anchor", ref: { path: p, node: n } };
      }
    }
    return null;
  }

  begin(point) {
    if (this.builder) {
      this.drag = { builder: true };
      this.pickFace(point);
      return;
    }
    const hit = this.hit(point);
    this.drag = { start: point, last: point, hit, moved: false };
    if (hit?.kind !== "anchor") return;
    const same = (a) => a.path === hit.ref.path && a.node === hit.ref.node;
    if (!this.picked.some(same)) this.picked = this.multiple ? [hit.ref, ...this.picked] : [hit.ref];
    else this.picked = [hit.ref, ...this.picked.filter((a) => !same(a))];
    this.drag.originals = this.picked.map((ref) => ({ ref, node: structuredClone(this.paths[ref.path].nodes[ref.node]) }));
    this.show();
    this.tools.renderOptions();
  }

  update(points) {
    const drag = this.drag;
    if (drag?.builder) {
      for (const point of points) this.pickFace(point);
      return;
    }
    if (!drag?.hit) return;
    const p = points.at(-1);
    drag.last = p;
    drag.moved = true;
    const dx = p.x - drag.start.x, dy = p.y - drag.start.y;
    if (drag.hit.kind === "anchor") {
      const shift = (pair) => pair && [pair[0] + dx, pair[1] + dy];
      for (const { ref, node } of drag.originals) {
        this.paths[ref.path].nodes[ref.node] = { ...node, x: node.x + dx, y: node.y + dy, in: shift(node.in), out: shift(node.out) };
      }
    } else {
      const ref = drag.hit.ref, node = this.paths[ref.path].nodes[ref.node];
      const isOut = drag.hit.kind === "out";
      node[isOut ? "out" : "in"] = [p.x, p.y];
      if (node.smooth) {
        // The other handle stays in line, keeping its length.
        const other = node[isOut ? "in" : "out"];
        const length = other ? Math.hypot(other[0] - node.x, other[1] - node.y) : Math.hypot(p.x - node.x, p.y - node.y);
        const angle = Math.atan2(p.y - node.y, p.x - node.x) + Math.PI;
        node[isOut ? "in" : "out"] = [node.x + Math.cos(angle) * length, node.y + Math.sin(angle) * length];
      }
    }
    this.show();
  }

  async end() {
    const drag = this.drag;
    if (!drag) return;
    this.drag = null;
    if (drag.builder) return;
    if (drag.moved) {
      await this.save();
      return;
    }
    if (drag.hit || !isTap(this.window, drag.start, drag.last)) return;
    // A tap on nothing: another vector layer is picked, or the points let go.
    const window = this.window;
    const { response } = await window.engine.call("hit", { doc: window.doc, x: drag.start.x, y: drag.start.y });
    const row = window.info.rows.find((r) => r.id === response.layer);
    this.picked = [];
    if (row?.type === "vector" && row.id !== window.selected) {
      window.select(row.id);
      return;
    }
    this.show();
    this.tools.renderOptions();
  }

  cancel() {
    const drag = this.drag;
    this.drag = null;
    if (drag?.moved) this.load();
  }

  toggleSmooth() {
    const ref = this.main, path = this.paths[ref.path], node = path.nodes[ref.node];
    if (node.smooth || node.in || node.out) {
      Object.assign(node, { in: null, out: null, smooth: false });
    } else {
      const count = path.nodes.length;
      const previous = ref.node > 0 ? path.nodes[ref.node - 1] : path.closed ? path.nodes[count - 1] : null;
      const next = ref.node < count - 1 ? path.nodes[ref.node + 1] : path.closed ? path.nodes[0] : null;
      const from = previous ?? node, to = next ?? node;
      const angle = Math.atan2(to.y - from.y, to.x - from.x);
      const lengthOut = next ? Math.hypot(next.x - node.x, next.y - node.y) / 3 : 0;
      const lengthIn = previous ? Math.hypot(previous.x - node.x, previous.y - node.y) / 3 : 0;
      node.out = [node.x + Math.cos(angle) * lengthOut, node.y + Math.sin(angle) * lengthOut];
      node.in = [node.x - Math.cos(angle) * lengthIn, node.y - Math.sin(angle) * lengthIn];
      node.smooth = true;
    }
    this.save();
  }

  /** A point halfway along the segment after the picked one, keeping the shape. */
  insert() {
    const ref = this.main, path = this.paths[ref.path], count = path.nodes.length;
    if (ref.node >= count - 1 && !path.closed) return;
    const next = (ref.node + 1) % count, start = path.nodes[ref.node], end = path.nodes[next];
    const mid = (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
    const p0 = [start.x, start.y], p3 = [end.x, end.y];
    let middle;
    if (!start.out && !end.in) {
      const [x, y] = mid(p0, p3);
      middle = { x, y, in: null, out: null, smooth: false };
    } else {
      const p1 = start.out ?? p0, p2 = end.in ?? p3;
      const a = mid(p0, p1), b = mid(p1, p2), c = mid(p2, p3), d = mid(a, b), e = mid(b, c), [x, y] = mid(d, e);
      start.out = a;
      end.in = c;
      middle = { x, y, in: d, out: e, smooth: true };
    }
    path.nodes.splice(ref.node + 1, 0, middle);
    this.picked = [{ path: ref.path, node: ref.node + 1 }];
    this.save();
  }

  deletePicked() {
    if (!this.main) return;
    // Highest first, so earlier positions stay right as points go.
    const doomed = [...this.picked].sort((a, b) => b.path - a.path || b.node - a.node);
    for (const ref of doomed) this.paths[ref.path]?.nodes.splice(ref.node, 1);
    this.picked = [];
    this.save();
  }

  show() {
    const window = this.window;
    if (!this.paths) {
      window.draft();
      return;
    }
    if (this.builder) {
      const { faces, picked, matrix } = this.builder;
      window.draft(`<g transform="${matrix}">${faces.map((face, index) => `<path class="app__draft-face${picked.has(index) ? " is-picked" : ""}" d="${face.data}"/>`).join("")}</g>`);
      return;
    }
    const isPicked = (p, n) => this.picked.some((ref) => ref.path === p && ref.node === n);
    const main = this.main;
    window.draft(
      this.paths.map((path) => `<path class="app__draft-line" d="${pathData(path.nodes, path.closed)}"/>`).join("")
      + this.paths.map((path, p) => path.nodes.map((node, n) => nodeMark(window, node, isPicked(p, n))).join("")).join("")
      + (main ? controlHandles(window, this.paths[main.path].nodes[main.node]) : ""),
    );
  }

  key(event) {
    if (event.key === "Escape" && this.builder) {
      this.perform("cancelBuilder");
      return true;
    }
    if ((event.key === "Backspace" || event.key === "Delete") && this.main) {
      event.preventDefault();
      this.deletePicked();
      return true;
    }
    if (event.key === "Escape" && this.picked.length) {
      this.picked = [];
      this.show();
      this.tools.renderOptions();
      return true;
    }
    return false;
  }
}

// ------------------------------------------------------------ Retouching

/**
 * Censor, Tone, Heal, Clone and Liquify: the stroke is marked over the
 * picture as it's drawn, and the engine works the effect through it when it
 * lifts. Clone first needs a source: a tap, or Option-click, picks one.
 */
class RetouchTool {
  constructor(tools, kind, { size = 60, strength = 0.8, variants = null, variant = null } = {}) {
    this.tools = tools;
    this.kind = kind;
    this.size = size;
    this.strength = strength;
    this.variants = variants;
    this.variant = variant;
    this.angle = 0;
    this.marks = [];
    this.source = null;
    this.offset = null;
    this.picking = false;
  }

  options() {
    const variants = this.variants ? choice("variant", this.kind === "tone" ? "Tone.Type" : "Censor.Type", this.variants, this.variant) : "";
    return variants
      + slider("size", "Options.Size", 1, 400, this.size)
      + (this.kind === "heal" ? "" : slider("strength", "Options.Strength", 1, 100, Math.round(this.strength * 100), "%"))
      + (this.variant === "motionBlur" ? slider("angle", "LayerFilters.Angle", 0, 180, this.angle, "°") : "")
      + (this.kind === "clone" ? action("source", "Options.CloneSource", this.picking || !this.source) : "");
  }

  bind(element) {
    bindOptions(element, (key, value) => {
      if (key === "strength") this.strength = value / 100;
      else this[key] = value;
      if (key === "variant") this.tools.renderOptions();
    });
    bindActions(element, (name, button) => {
      this.picking = !this.picking;
      button.setAttribute("aria-pressed", String(this.picking));
    });
  }

  enter() {
    this.show();
  }

  leave() {
    this.tools.window.draft();
  }

  begin(point, event) {
    if (this.kind === "clone" && (this.picking || !this.source || event.altKey)) {
      this.source = point;
      this.offset = null;
      this.picking = false;
      this.stroke = null;
      this.tools.renderOptions();
      this.show();
      return;
    }
    if (this.kind === "clone" && !this.offset) this.offset = { x: this.source.x - point.x, y: this.source.y - point.y };
    this.stroke = [point];
    this.show();
  }

  update(points) {
    if (!this.stroke) return;
    this.stroke.push(...points);
    this.show();
  }

  show() {
    const window = this.tools.window;
    const mark = (points) => points.length === 1
      ? `<circle class="app__draft-mark" cx="${number(points[0].x)}" cy="${number(points[0].y)}" r="${number(this.size / 4)}" stroke-width="${number(this.size / 2)}"/>`
      : `<path class="app__draft-mark" d="${polyline(points)}" stroke-width="${number(this.size)}"/>`;
    let markup = [...this.marks, ...(this.stroke ? [this.stroke] : [])].map(mark).join("");
    if (this.kind === "clone" && this.source) {
      const last = this.stroke?.at(-1);
      const at = last && this.offset ? { x: last.x + this.offset.x, y: last.y + this.offset.y } : this.source;
      const arm = 10 / window.zoom;
      markup += `<path class="app__draft-line" d="M${number(at.x - arm)} ${number(at.y)}h${number(arm * 2)}M${number(at.x)} ${number(at.y - arm)}v${number(arm * 2)}"/>`;
    }
    window.draft(markup);
  }

  async end() {
    const stroke = this.stroke;
    this.stroke = null;
    if (!stroke) return;
    const kind = this.kind === "censor" || this.kind === "tone" ? (this.kind === "tone" ? "tone" : this.variant) : this.kind;
    const params = {
      kind, points: stroke.flatMap((p) => [p.x, p.y, 1]), size: this.size, opacity: this.kind === "heal" ? 1 : this.strength, softness: 0.5,
    };
    if (this.kind === "tone") params.tone = this.variant;
    if (kind === "motionBlur") params.angle = this.angle;
    if (this.kind === "clone") Object.assign(params, { dx: this.offset.x, dy: this.offset.y });
    if (this.kind === "clone") {
      const last = stroke.at(-1);
      this.source = { x: last.x + this.offset.x, y: last.y + this.offset.y };
    }
    this.marks.push(stroke);
    this.show();
    await this.tools.window.edit("stroke", params);
    this.marks.splice(this.marks.indexOf(stroke), 1);
    if (this.tools.current === this) this.show();
  }

  cancel() {
    this.stroke = null;
    this.show();
  }
}

// ------------------------------------------------------------ The picker and the canvas's pointers

export class Tools {
  constructor(window) {
    this.window = window;
    this.color = "#000000";
    this.tools = {
      brush: new BrushTool(this, { erases: false, size: 12, softness: 0 }),
      eraser: new BrushTool(this, { erases: true, size: 60, softness: 0.3 }),
      fill: new FillTool(this),
      eyedropper: new EyedropperTool(this),
      move: new MoveTool(this),
      select: new SelectTool(this),
      crop: new CropTool(this),
      gradient: new GradientTool(this),
      liquify: new RetouchTool(this, "liquify", { size: 80, strength: 0.6 }),
      censor: new RetouchTool(this, "censor", {
        variants: [["blur", "LayerFilter.GaussianBlur"], ["mosaic", "LayerFilter.Mosaic"], ["motionBlur", "LayerFilter.MotionBlur"], ["smudge", "Tool.Smudge"]],
        variant: "blur",
      }),
      tone: new RetouchTool(this, "tone", {
        strength: 0.3,
        variants: [["dodge", "Tone.Dodge"], ["burn", "Tone.Burn"], ["saturate", "Tone.Saturate"], ["desaturate", "Tone.Desaturate"], ["sharpen", "Tone.Sharpen"], ["soften", "Tone.Soften"], ["redEye", "Tone.RedEye"]],
        variant: "dodge",
      }),
      heal: new RetouchTool(this, "heal", { size: 40 }),
      clone: new RetouchTool(this, "clone", { size: 40, strength: 1 }),
      text: new TextTool(this),
      shape: new ShapeTool(this),
      transform: new TransformTool(this),
      pen: new PenTool(this),
      nodes: new NodesTool(this),
    };
    this.id = "brush";
    this.previous = null;
    this.pointers = new Map();
    this.gesture = null;
    this.drawing = false;
    this.picker = window.root.querySelector(".app__tools");
    this.options = window.root.querySelector(".app__options-tools");
    this.renderPicker();
    this.renderOptions();
    this.picker.addEventListener("click", (event) => {
      const button = event.target.closest("[data-tool]");
      if (button && !button.disabled) this.choose(button.dataset.tool);
    });
    const viewport = window.viewport;
    viewport.addEventListener("pointerdown", (event) => this.down(event));
    viewport.addEventListener("pointermove", (event) => this.move(event));
    viewport.addEventListener("pointerup", (event) => this.up(event));
    viewport.addEventListener("pointercancel", (event) => this.up(event, true));
  }

  get current() {
    return this.tools[this.id];
  }

  renderPicker() {
    this.picker.innerHTML = GROUPS.map((group) => group.map((id) => {
      const label = escapeHTML(t(LABELS[id]));
      const works = id in this.tools;
      return `<button class="ds-button ds-button--ghost ds-button--icon app__tool" data-tool="${id}" title="${label}" aria-label="${label}" aria-pressed="${id === this.id}"${works ? "" : " disabled"}>${icon(ICONS[id])}</button>`;
    }).join("")).join('<div class="app__tools-separator" role="separator"></div>');
  }

  choose(id) {
    if (!(id in this.tools) || id === this.id) return;
    this.cancel();
    this.current.leave?.();
    if (id === "eyedropper") this.previous = this.id;
    this.id = id;
    for (const button of this.picker.querySelectorAll("[data-tool]")) button.setAttribute("aria-pressed", String(button.dataset.tool === id));
    this.renderOptions();
    this.reveal();
    this.current.enter?.();
  }

  /** A document was opened or closed: what the tools had drawn over the last one goes. */
  reset() {
    this.cancel();
    this.current.leave?.();
    this.current.enter?.();
  }

  /** The layer picked, or the document, changed. */
  changed() {
    this.current.changed?.();
  }

  /** A key pressed over the canvas; true if the tool in hand used it. */
  key(event) {
    if (event.key === "Escape" && this.drawing) {
      this.cancel();
      return true;
    }
    return this.current.key?.(event) ?? false;
  }

  // Along the bottom of a phone the row scrolls; the tool in hand is kept in view.
  reveal() {
    const button = this.picker.querySelector(`[data-tool="${this.id}"]`);
    if (!button || this.picker.scrollWidth <= this.picker.clientWidth) return;
    const offset = button.getBoundingClientRect().left - this.picker.getBoundingClientRect().left + this.picker.scrollLeft;
    this.picker.scrollLeft = offset - (this.picker.clientWidth - button.offsetWidth) / 2;
  }

  renderOptions() {
    this.options.innerHTML = this.current.options();
    this.current.bind(this.options);
  }

  // ------------------------------------------------------------ Pointers

  point(event) {
    const point = this.window.pictureAt(event.clientX, event.clientY);
    return { ...point, pressure: event.pointerType === "pen" && event.pressure > 0 ? event.pressure : 1 };
  }

  down(event) {
    if (this.window.doc === null || this.window.viewport.hidden) return;
    if (event.pointerType === "mouse" && event.button !== 0) return;
    this.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    this.window.viewport.setPointerCapture?.(event.pointerId);
    event.preventDefault();
    if (this.pointers.size === 2) {
      this.cancel();
      this.beginGesture();
      return;
    }
    if (this.pointers.size > 2 || this.gesture) return;
    this.drawing = true;
    this.current.begin(this.point(event), event);
  }

  move(event) {
    if (!this.pointers.has(event.pointerId)) return;
    this.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (this.gesture) {
      this.updateGesture();
      return;
    }
    if (!this.drawing) return;
    const events = event.getCoalescedEvents?.() ?? [];
    this.current.update((events.length ? events : [event]).map((e) => this.point(e)));
  }

  up(event, cancelled = false) {
    if (!this.pointers.delete(event.pointerId)) return;
    if (this.gesture) {
      if (this.pointers.size === 0) this.endGesture();
      else this.beginGesture();
      return;
    }
    if (!this.drawing) return;
    this.drawing = false;
    if (cancelled) this.current.cancel();
    else this.current.end();
  }

  cancel() {
    if (!this.drawing) return;
    this.drawing = false;
    this.current.cancel();
  }

  // Two fingers pan, pinch and turn, whatever the tool.
  beginGesture() {
    const [a, b] = [...this.pointers.values()];
    if (this.gesture?.turning) this.window.settleRotation();
    this.gesture = b
      ? {
        mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
        distance: Math.hypot(a.x - b.x, a.y - b.y) || 1,
        angle: Math.atan2(b.y - a.y, b.x - a.x),
        zoom: this.window.zoom,
        rotation: this.window.rotation,
        turning: false,
      }
      : { single: true };
  }

  updateGesture() {
    const [a, b] = [...this.pointers.values()];
    const gesture = this.gesture;
    if (!b || gesture.single) return;
    const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    const viewport = this.window.viewport;
    const rect = viewport.getBoundingClientRect();
    viewport.scrollLeft -= mid.x - gesture.mid.x;
    viewport.scrollTop -= mid.y - gesture.mid.y;
    gesture.mid = mid;
    const zoom = gesture.zoom * Math.hypot(a.x - b.x, a.y - b.y) / gesture.distance;
    // A turn starts only past a small twist, so a pinch doesn't wobble the canvas.
    let twist = Math.atan2(b.y - a.y, b.x - a.x) - gesture.angle;
    twist = Math.atan2(Math.sin(twist), Math.cos(twist));
    if (!gesture.turning && Math.abs(twist) >= TURN_THRESHOLD) {
      gesture.turning = true;
      gesture.angle += twist;
      twist = 0;
    }
    const rotation = gesture.turning ? gesture.rotation + twist : this.window.rotation;
    if (Math.abs(zoom - this.window.zoom) > 0.001 || rotation !== this.window.rotation) {
      this.window.setView({ zoom, rotation }, { x: mid.x - rect.left, y: mid.y - rect.top });
    }
  }

  endGesture() {
    if (this.gesture?.turning) this.window.settleRotation();
    this.gesture = null;
  }

}
