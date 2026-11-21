// Sets type for the engine (Web/engine/swift/Sources/Portable/AppKit), which
// asks synchronously while it draws a text layer. The browser has the fonts,
// so text is measured and drawn with an OffscreenCanvas in the engine's
// worker. Where there's no canvas (Node), the engine estimates instead.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const designs = {
  default: '-apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", "Helvetica Neue", Arial, sans-serif',
  serif: 'ui-serif, "New York", Georgia, "Times New Roman", serif',
  rounded: 'ui-rounded, "SF Pro Rounded", "Arial Rounded MT Bold", system-ui, sans-serif',
  monospaced: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', // design-lint-allow (document content)
};

function cssFont(fragment) {
  const family = fragment.family ? `"${fragment.family.replace(/"/g, "")}", ` : "";
  return `${fragment.italic ? "italic " : ""}${fragment.bold ? "700" : "400"} ${fragment.size}px ${family}${designs[fragment.design] || designs.default}`;
}

function cssColor(c) {
  return `rgba(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)}, ${c[3]})`;
}

export class TextHost {
  constructor() {
    this.canvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(1, 1) : null;
    this.context = this.canvas?.getContext("2d", { willReadFrequently: true }) ?? null;
    this.result = new Uint8Array(0);
    this.memory = null;
  }

  /** @param {() => WebAssembly.Memory} memory */
  imports(memory) {
    return {
      text: (pointer, length) => {
        if (!this.context) return -1;
        try {
          const request = JSON.parse(decoder.decode(new Uint8Array(memory().buffer, pointer, length)));
          this.result = this.answer(request);
          return this.result.length;
        } catch (error) {
          console.warn("[text]", error);
          return -1;
        }
      },
      result: (pointer) => {
        new Uint8Array(memory().buffer, pointer, this.result.length).set(this.result);
      },
    };
  }

  answer(request) {
    switch (request.op) {
      case "font":
        return encoder.encode(this.isInstalled(request.family) ? "1" : "0");
      case "layout":
        return encoder.encode(JSON.stringify(this.layout(request)));
      case "draw":
        return this.draw(request);
      default:
        return new Uint8Array(0);
    }
  }

  isInstalled(family) {
    const fonts = globalThis.fonts ?? globalThis.document?.fonts;
    try {
      if (fonts?.check && !fonts.check(`12px "${family}"`)) return false;
    } catch {
      return false;
    }
    // check() is true for families it doesn't know; compare against a fallback's widths.
    const context = this.context;
    const sample = "mmmmmmmmmmlli1WQ@";
    context.font = `40px monospace`; // design-lint-allow (font detection)
    const mono = context.measureText(sample).width;
    context.font = `40px "${family}", monospace`; // design-lint-allow (font detection)
    const withFamily = context.measureText(sample).width;
    context.font = `40px serif`;
    const serif = context.measureText(sample).width;
    context.font = `40px "${family}", serif`;
    return withFamily !== mono || context.measureText(sample).width !== serif;
  }

  measure(fragment, text) {
    const context = this.context;
    context.font = cssFont(fragment);
    const metrics = context.measureText(text);
    return {
      width: metrics.width + fragment.tracking * [...text].length,
      ascent: metrics.fontBoundingBoxAscent ?? fragment.size * 0.8,
      descent: metrics.fontBoundingBoxDescent ?? fragment.size * 0.2,
    };
  }

  /** Lines broken to fit `width`, with each piece's place. */
  layout({ fragments, width, align, lineHeight }) {
    const tokens = [];
    let offset = 0;
    fragments.forEach((fragment, index) => {
      for (const part of fragment.text.split(/(\n|\s+)/)) {
        if (!part) continue;
        if (part === "\n") tokens.push({ fragment: index, start: offset, length: 1, newline: true });
        else tokens.push({ fragment: index, start: offset, length: part.length, text: part, space: /^\s+$/.test(part) });
        offset += part.length;
      }
    });
    const lines = [];
    let line = { pieces: [], width: 0, ascent: 0, descent: 0 };
    const finish = () => {
      // Spaces at the end of a broken line don't count towards its width.
      while (line.pieces.length && line.pieces[line.pieces.length - 1].space) {
        const last = line.pieces.pop();
        line.width -= last.width;
      }
      if (!line.ascent) {
        const fragment = fragments[Math.min(line.lastFragment ?? 0, fragments.length - 1)] ?? { size: 12 };
        const m = fragments.length ? this.measure(fragment, " ") : { ascent: 10, descent: 2 };
        line.ascent = m.ascent;
        line.descent = m.descent;
      }
      lines.push(line);
      line = { pieces: [], width: 0, ascent: 0, descent: 0, lastFragment: line.lastFragment };
    };
    for (const token of tokens) {
      if (token.newline) {
        line.lastFragment = token.fragment;
        finish();
        continue;
      }
      const fragment = fragments[token.fragment];
      const m = this.measure(fragment, token.text);
      if (width && line.width + m.width > width && line.pieces.some((p) => !p.space) && !token.space) finish();
      if (token.space && !line.pieces.length && lines.length && width) continue;
      line.pieces.push({ fragment: token.fragment, start: token.start, length: token.length, x: line.width, width: m.width, space: token.space });
      line.width += m.width;
      line.ascent = Math.max(line.ascent, m.ascent);
      line.descent = Math.max(line.descent, m.descent);
      line.lastFragment = token.fragment;
    }
    finish();
    const boxWidth = width ?? Math.max(0, ...lines.map((l) => l.width));
    let y = 0;
    const result = lines.map((l) => {
      const height = (l.ascent + l.descent) * (lineHeight || 1);
      const baseline = y + height - l.descent;
      y += height;
      const free = Math.max(0, boxWidth - l.width);
      const x = align === "center" ? free / 2 : align === "right" ? free : 0;
      // Neighbouring pieces of one fragment become one.
      const pieces = [];
      for (const piece of l.pieces) {
        const last = pieces[pieces.length - 1];
        if (last && last.fragment === piece.fragment && last.start + last.length === piece.start) {
          last.length += piece.length;
          last.width = piece.x + piece.width - last.x;
        } else {
          pieces.push({ fragment: piece.fragment, start: piece.start, length: piece.length, x: piece.x + x, width: piece.width });
        }
      }
      return { x, baseline, ascent: l.ascent, descent: l.descent, width: l.width, pieces };
    });
    return { width: Math.max(0, ...lines.map((l) => l.width)), height: y, lines: result };
  }

  draw(request) {
    const { fragments, pixelWidth, pixelHeight, scale } = request;
    const layout = this.layout(request);
    const canvas = this.canvas;
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
    const context = this.context;
    context.setTransform(scale, 0, 0, scale, 0, 0);
    context.clearRect(0, 0, pixelWidth, pixelHeight);
    const whole = fragments.map((f) => f.text).join("");
    for (const line of layout.lines) {
      for (const piece of line.pieces) {
        const fragment = fragments[piece.fragment];
        const text = whole.slice(piece.start, piece.start + piece.length);
        context.font = cssFont(fragment);
        if ("letterSpacing" in context) context.letterSpacing = `${fragment.tracking || 0}px`; // design-lint-allow (document content)
        const y = line.baseline - (fragment.baseline || 0);
        const strokeWidth = fragment.strokeWidth ?? 0;
        if (strokeWidth <= 0) {
          context.fillStyle = cssColor(fragment.color);
          context.fillText(text, piece.x, y);
        }
        if (strokeWidth !== 0 && fragment.strokeColor) {
          context.strokeStyle = cssColor(fragment.strokeColor);
          context.lineWidth = (Math.abs(strokeWidth) / 100) * fragment.size;
          context.lineJoin = "round";
          context.strokeText(text, piece.x, y);
        }
        if (fragment.underline) {
          context.fillStyle = cssColor(fragment.color);
          context.fillRect(piece.x, y + fragment.size * 0.1, piece.width, Math.max(1, fragment.size * 0.06));
        }
      }
    }
    return new Uint8Array(context.getImageData(0, 0, pixelWidth, pixelHeight).data.buffer);
  }
}
