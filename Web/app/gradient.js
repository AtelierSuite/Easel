// The gradient editor: a gradient's stops along a bar, as the Apple apps'
// gradient well opens it. Tap the bar to add a stop, drag one along, pick
// one to change its colour or take it away, or start from a preset.

import { openMenu } from "../design/menus.js";
import { dismissSheet } from "../design/sheets.js";
import { t } from "./i18n.js";

const escapeHTML = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const css = (color) => `rgb(${color.slice(0, 3).map((v) => Math.round(v * 255)).join(" ")} / ${color[3]})`;
const toHex = (color) => `#${color.slice(0, 3).map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("")}`;
const fromHex = (hex, alpha) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).concat(alpha);

export const GRADIENT_PRESETS = [
  ["fading", "Gradient.Preset.Fading"], ["toWhite", "Gradient.Preset.ToWhite"], ["blackToWhite", "Gradient.Preset.BlackToWhite"],
  ["rainbow", "Gradient.Preset.Rainbow"], ["sunset", "Gradient.Preset.Sunset"], ["ocean", "Gradient.Preset.Ocean"],
];

/** A preset's stops, `color` standing for the brush colour. */
export function presetStops(preset, color) {
  const stop = (location, r, g, b, a = 1) => ({ location, color: [r, g, b, a] });
  switch (preset) {
    case "toWhite": return [{ location: 0, color: [...color.slice(0, 3), 1] }, stop(1, 1, 1, 1)];
    case "blackToWhite": return [stop(0, 0, 0, 0), stop(1, 1, 1, 1)];
    case "rainbow": return [stop(0, 1, 0, 0), stop(0.17, 1, 0.6, 0), stop(0.33, 1, 1, 0), stop(0.5, 0, 0.8, 0), stop(0.67, 0, 0.5, 1), stop(0.83, 0.3, 0, 0.8), stop(1, 0.6, 0, 0.7)];
    case "sunset": return [stop(0, 0.25, 0.1, 0.45), stop(0.5, 0.95, 0.35, 0.4), stop(1, 1, 0.8, 0.35)];
    case "ocean": return [stop(0, 0, 0.15, 0.35), stop(0.55, 0, 0.55, 0.75), stop(1, 0.65, 0.95, 0.9)];
    default: return [{ location: 0, color: [...color.slice(0, 3), 1] }, { location: 1, color: [...color.slice(0, 3), 0] }];
  }
}

/** The stops as the engine takes them: location then red, green, blue and alpha, for each. */
export const flatStops = (stops) => [...stops].sort((a, b) => a.location - b.location).flatMap((s) => [s.location, ...s.color]);

/** The stops as a CSS gradient running left to right. */
export function gradientCSS(stops) {
  return `linear-gradient(to right, ${[...stops].sort((a, b) => a.location - b.location).map((s) => `${css(s.color)} ${Math.round(s.location * 1000) / 10}%`).join(", ")})`;
}

/** A button showing the gradient, for an options bar. */
export function gradientWell(stops, name = "gradientWell") {
  const label = escapeHTML(t("Gradient.Edit"));
  return `<button type="button" class="app__gradient-well app__option" data-tool-action="${name}" title="${label}" aria-label="${label}"><span style="background-image: ${gradientCSS(stops)}"></span></button>`;
}

function colorAt(stops, location) {
  const sorted = [...stops].sort((a, b) => a.location - b.location);
  const after = sorted.findIndex((s) => s.location >= location);
  if (after < 0) return [...sorted.at(-1).color];
  if (after === 0) return [...sorted[0].color];
  const a = sorted[after - 1], b = sorted[after];
  const f = b.location > a.location ? (location - a.location) / (b.location - a.location) : 0;
  return a.color.map((v, i) => v + (b.color[i] - v) * f);
}

/**
 * Opens the editor in a sheet over `win`; resolves to the edited stops, or
 * null if cancelled. `color` is the brush colour presets follow.
 */
export function editGradient(win, stops, color) {
  return new Promise((resolve) => {
    let current = stops.map((s) => ({ location: s.location, color: [...s.color] }));
    let picked = 0;
    let answer = null;
    const backdrop = win.sheet(`
      <form class="ds-sheet app__gradient-editor" role="dialog" aria-labelledby="gradient-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="gradient-title">${escapeHTML(t("Gradient.Edit"))}</h2>
          <button type="button" class="ds-button ds-button--bordered ds-button--xs" data-presets>${escapeHTML(t("Gradient.Presets"))}</button>
          <div class="app__gradient-bar"><div class="app__gradient-fill"></div><div class="app__gradient-stops"></div></div>
          <div class="app__gradient-stop">
            <label class="ds-form__label" for="gradient-color">${escapeHTML(t("Gradient.StopColor"))}</label>
            <input type="color" class="ds-color-well" id="gradient-color">
            <input type="range" class="app__gradient-alpha" min="0" max="100" aria-label="${escapeHTML(t("Options.Opacity"))}">
            <button type="button" class="ds-button ds-button--bordered ds-button--xs" data-remove>${escapeHTML(t("Gradient.RemoveStop"))}</button>
          </div>
          <p class="ds-caption">${escapeHTML(t("Gradient.Footer"))}</p>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Common.Done"))}</button>
        </div>
      </form>`);
    const form = backdrop.querySelector("form");
    const bar = form.querySelector(".app__gradient-bar");
    const fill = form.querySelector(".app__gradient-fill");
    const knobs = form.querySelector(".app__gradient-stops");
    const well = form.querySelector("#gradient-color");
    const alpha = form.querySelector(".app__gradient-alpha");
    const remove = form.querySelector("[data-remove]");

    const render = () => {
      fill.style.backgroundImage = gradientCSS(current);
      knobs.innerHTML = current.map((s, i) => `<button type="button" class="app__gradient-knob" data-stop="${i}" aria-pressed="${i === picked}" style="left: ${s.location * 100}%; --stop: ${css([...s.color.slice(0, 3), 1])}" aria-label="${escapeHTML(t("Gradient.StopColor"))} ${Math.round(s.location * 100)}%"></button>`).join("");
      well.value = toHex(current[picked].color);
      alpha.value = String(Math.round(current[picked].color[3] * 100));
      remove.disabled = current.length <= 2;
    };
    const locationAt = (clientX) => {
      const rect = bar.getBoundingClientRect();
      return Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    };

    bar.addEventListener("pointerdown", (event) => {
      const knob = event.target.closest("[data-stop]");
      if (!knob) {
        const location = locationAt(event.clientX);
        current.push({ location, color: colorAt(current, location) });
        picked = current.length - 1;
        render();
        return;
      }
      picked = Number(knob.dataset.stop);
      render();
      const target = knobs.querySelector(`[data-stop="${picked}"]`);
      target.setPointerCapture(event.pointerId);
      const move = (e) => {
        current[picked].location = locationAt(e.clientX);
        target.style.left = `${current[picked].location * 100}%`;
        fill.style.backgroundImage = gradientCSS(current);
      };
      target.addEventListener("pointermove", move);
      target.addEventListener("pointerup", () => {
        target.removeEventListener("pointermove", move);
        render();
      }, { once: true });
    });
    well.addEventListener("input", () => {
      current[picked].color = fromHex(well.value, current[picked].color[3]);
      render();
    });
    alpha.addEventListener("input", () => {
      current[picked].color[3] = Number(alpha.value) / 100;
      fill.style.backgroundImage = gradientCSS(current);
    });
    remove.addEventListener("click", () => {
      if (current.length <= 2) return;
      current.splice(picked, 1);
      picked = Math.max(0, picked - 1);
      render();
    });
    form.querySelector("[data-presets]").addEventListener("click", (event) => {
      openMenu(GRADIENT_PRESETS.map(([id, label]) => ({
        label: t(label),
        action: () => {
          current = presetStops(id, color);
          picked = 0;
          render();
        },
      })), event.currentTarget);
    });
    const observer = new MutationObserver(() => {
      if (backdrop.isConnected) return;
      observer.disconnect();
      resolve(answer);
    });
    observer.observe(win.root, { childList: true });
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      answer = current;
      dismissSheet(backdrop);
    });
    render();
  });
}
