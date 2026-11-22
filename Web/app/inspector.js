// The Layers inspector: the stack with its eyes, thumbnails and badges, the
// picked layer's or group's settings, its mask, and the buttons that add,
// copy, combine and delete layers, as the Apple apps' Layers panel has them.

import { openMenu } from "../design/menus.js";
import { t } from "./i18n.js";
import { chooseFile, decodePicture } from "./files.js";

const icon = (path) => `<svg class="ds-icon" viewBox="0 0 16 16" aria-hidden="true">${path}</svg>`;
const ICONS = {
  eye: icon('<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z" fill="none" stroke="currentColor"/><circle cx="8" cy="8" r="2" fill="none" stroke="currentColor"/>'),
  eyeOff: icon('<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z" fill="none" stroke="currentColor" opacity=".45"/><path d="M2.5 13.5l11-11" stroke="currentColor"/>'),
  folder: icon('<path d="M1.5 4.5v8h13v-7h-6l-1.5-1.5h-5.5z" fill="none" stroke="currentColor"/>'),
  chevron: icon('<path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.5"/>'),
  text: icon('<path d="M3 3.5h10M8 3.5v10" stroke="currentColor" stroke-width="1.5"/>'),
  vector: icon('<path d="M3 13C5 5 11 11 13 3" fill="none" stroke="currentColor"/><rect x="1.5" y="11.5" width="3" height="3" fill="none" stroke="currentColor"/><rect x="11.5" y="1.5" width="3" height="3" fill="none" stroke="currentColor"/>'),
  adjustment: icon('<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor"/><path d="M8 2a6 6 0 0 1 0 12z" fill="currentColor"/>'),
  smart: icon('<rect x="2.5" y="2.5" width="11" height="11" fill="none" stroke="currentColor"/><path d="M5 11l2.5-3 2 2 1.5-2" fill="none" stroke="currentColor"/>'),
  plus: icon('<path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5"/>'),
  duplicate: icon('<rect x="5.5" y="5.5" width="8" height="8" fill="none" stroke="currentColor"/><path d="M3.5 10.5h-1v-8h8v1" fill="none" stroke="currentColor"/>'),
  mergeDown: icon('<path d="M8 1.5v6M5.5 5L8 7.5 10.5 5" fill="none" stroke="currentColor"/><path d="M8 9l6.5 2.5L8 14l-6.5-2.5z" fill="currentColor"/>'),
  trash: icon('<path d="M2.5 4h11M6 4V2.5h4V4M4 4l.7 9.5h6.6L12 4" fill="none" stroke="currentColor"/>'),
  more: icon('<circle cx="3.5" cy="8" r="1.2" fill="currentColor"/><circle cx="8" cy="8" r="1.2" fill="currentColor"/><circle cx="12.5" cy="8" r="1.2" fill="currentColor"/>'),
  lock: icon('<rect x="3.5" y="7" width="9" height="7" rx="1" fill="currentColor"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" fill="none" stroke="currentColor"/>'),
  clipped: icon('<path d="M4 2.5v6.5h7M8.5 6.5L11 9l-2.5 2.5" fill="none" stroke="currentColor"/>'),
  mask: icon('<rect x="1.5" y="2.5" width="13" height="11" rx="1" fill="none" stroke="currentColor"/><circle cx="8" cy="8" r="3.5" fill="currentColor"/>'),
};

const escapeHTML = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const LONG_PRESS = 500;

function slider(key, label, min, max, value, text, step = 1) {
  return `
    <label class="ds-form__label" for="inspector-${key}">${escapeHTML(label)}</label>
    <div class="ds-slider"><input id="inspector-${key}" type="range" data-setting="${key}" min="${min}" max="${max}" step="${step}" value="${value}"><span class="ds-numeric app__setting-value" data-shows="${key}">${escapeHTML(text)}</span></div>`;
}

function popup(key, label, options, value) {
  return `
    <label class="ds-form__label" for="inspector-${key}">${escapeHTML(label)}</label>
    <span class="ds-popup ds-popup--xs"><select class="ds-popup__select" id="inspector-${key}" data-setting="${key}">${options
      .map(([id, text]) => `<option value="${escapeHTML(id)}"${String(id) === String(value) ? " selected" : ""}>${escapeHTML(text)}</option>`)
      .join("")}</select><svg class="ds-icon ds-popup__chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg></span>`;
}

function toggle(key, label, checked, disabled = false) {
  return `<label class="ds-switch app__setting-wide"><input type="checkbox" role="switch" data-setting="${key}"${checked ? " checked" : ""}${disabled ? " disabled" : ""}>${escapeHTML(label)}</label>`;
}

function button(key, label, { disabled = false, destructive = false } = {}) {
  return `<button type="button" class="ds-button ds-button--bordered ds-button--xs app__setting-wide${destructive ? " app__setting-destructive" : ""}" data-command="${key}"${disabled ? " disabled" : ""}>${escapeHTML(label)}</button>`;
}

const heading = (text) => `<h3 class="ds-heading-compact app__setting-heading">${escapeHTML(text)}</h3>`;
const percent = (value) => `${Math.round(value * 100)}%`;

function parameterText(parameter, value) {
  switch (parameter.style) {
    case "percent": return `${Math.round(value * 100)}%`;
    case "signedPercent": return `${value > 0 ? "+" : ""}${Math.round(value)}%`;
    case "degrees": return `${Math.round(value)}°`;
    case "decimal": return value.toFixed(2);
    default: return String(Math.round(value));
  }
}

export class LayersInspector {
  constructor(win, aside) {
    this.window = win;
    this.aside = aside;
    aside.innerHTML = `
      <div class="ds-inspector__body app__layers-body">
        <h2 class="ds-heading-compact app__layers-title">${escapeHTML(t("Web.Layers.Title"))}</h2>
        <div class="ds-source-list app__layers" role="listbox" aria-label="${escapeHTML(t("Web.Layers.Title"))}"></div>
        <div class="app__layer-settings"></div>
      </div>
      <div class="app__layer-actions" role="toolbar" aria-label="${escapeHTML(t("Web.Layers.Title"))}">
        ${this.actionButton("add", "Layers.Add", ICONS.plus)}
        ${this.actionButton("duplicate", "Layers.Duplicate", ICONS.duplicate)}
        ${this.actionButton("mergeDown", "Layers.MergeDown", ICONS.mergeDown)}
        ${this.actionButton("delete", "Layers.Delete", ICONS.trash)}
        <span class="app__layer-actions-spacer"></span>
        ${this.actionButton("more", "Layers.More", ICONS.more)}
      </div>`;
    this.list = aside.querySelector(".app__layers");
    this.settings = aside.querySelector(".app__layer-settings");
    this.actions = aside.querySelector(".app__layer-actions");

    this.list.addEventListener("click", (event) => this.clicked(event));
    this.list.addEventListener("dblclick", (event) => this.doubleClicked(event));
    this.list.addEventListener("keydown", (event) => this.key(event));
    this.list.addEventListener("contextmenu", (event) => {
      const item = event.target.closest(".app__layer");
      if (!item) return;
      event.preventDefault();
      this.showRowMenu(item.dataset.id, { x: event.clientX, y: event.clientY });
    });
    this.list.addEventListener("pointerdown", (event) => this.pointerDown(event));
    this.actions.addEventListener("click", (event) => {
      const target = event.target.closest("[data-layer-action]");
      if (target && !target.disabled) this.perform(target.dataset.layerAction, target);
    });
    this.settings.addEventListener("input", (event) => this.settingMoved(event));
    this.settings.addEventListener("change", (event) => this.settingChanged(event));
    this.settings.addEventListener("click", (event) => {
      const target = event.target.closest("[data-command]");
      if (target && !target.disabled) this.command(target.dataset.command, target);
    });
  }

  actionButton(action, label, svg) {
    const text = escapeHTML(t(label));
    return `<button type="button" class="ds-button ds-button--ghost ds-button--icon" data-layer-action="${action}" title="${text}" aria-label="${text}">${svg}</button>`;
  }

  get info() {
    return this.window.info;
  }

  row(id = this.window.selected) {
    return this.info?.rows.find((row) => row.id === id) ?? null;
  }

  layers(args, { select = true } = {}) {
    return this.window.edit("layers", args, { all: true, select });
  }

  // ------------------------------------------------------------ Showing

  render() {
    const focused = this.list.contains(document.activeElement);
    this.list.replaceChildren(...this.info.rows.map((row) => this.rowElement(row)));
    if (focused) this.list.querySelector('[aria-selected="true"]')?.focus();
    this.renderSettings();
    this.renderActions();
    this.loadThumbnails();
  }

  rowElement(row) {
    const item = document.createElement("div");
    const selected = row.id === this.window.selected;
    item.className = "ds-source-list__item app__layer";
    item.setAttribute("role", "option");
    item.dataset.id = row.id;
    item.tabIndex = selected ? 0 : -1;
    item.setAttribute("aria-selected", String(selected));
    if (selected) item.setAttribute("aria-current", "true");
    item.style.setProperty("--depth", row.depth);
    item.classList.toggle("is-hidden", !row.visible);
    const visibility = escapeHTML(row.visible ? t("Layers.Hide") : t("Layers.Show"));
    const eye = `<button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__eye" data-toggle title="${visibility}" aria-label="${visibility}" aria-pressed="${row.visible}">${row.visible ? ICONS.eye : ICONS.eyeOff}</button>`;
    const lock = row.locked ? `<span class="app__layer-state" title="${escapeHTML(t("Layers.Locked"))}">${ICONS.lock}</span>` : "";
    const details = [];
    if (row.blendMode !== "normal" && row.blendMode !== "passThrough") details.push(this.info.blendModes.find((mode) => mode.id === row.blendMode)?.label ?? row.blendMode);
    if (row.opacity < 0.995) details.push(percent(row.opacity));
    const detail = details.length ? `<span class="ds-caption app__layer-detail">${escapeHTML(details.join(" · "))}</span>` : "";
    if (row.kind === "group") {
      const expand = escapeHTML(row.expanded ? t("Groups.Collapse") : t("Groups.Expand"));
      item.innerHTML = `
        ${eye}
        <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__disclosure${row.expanded ? " is-open" : ""}" data-expand aria-expanded="${row.expanded}" title="${expand}" aria-label="${expand}">${ICONS.chevron}</button>
        <span class="app__layer-folder">${ICONS.folder}</span>
        <span class="app__layer-text"><span class="app__layer-name">${escapeHTML(row.name)}</span>${detail}</span>
        ${lock}`;
      return item;
    }
    const kind = { text: "text", vector: "vector", adjustment: "adjustment", smart: "smart" }[row.type];
    const editing = selected && (this.window.editingMask || row.type === "adjustment");
    const mask = row.masked
      ? `<button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__mask-button${editing ? " is-target" : ""}${row.maskEnabled ? "" : " is-off"}" data-mask title="${escapeHTML(t("Mask.Edit"))}" aria-label="${escapeHTML(t("Mask.Edit"))}" aria-pressed="${editing}">${ICONS.mask}</button>`
      : "";
    item.innerHTML = `
      ${eye}
      ${row.clipped ? `<span class="app__layer-state" title="${escapeHTML(t("Layers.Clipped"))}">${ICONS.clipped}</span>` : ""}
      <canvas class="app__thumbnail${selected && !editing && row.type !== "adjustment" ? " is-target" : ""}" width="48" height="48" aria-hidden="true"></canvas>
      ${mask}
      <span class="app__layer-text"><span class="app__layer-name">${escapeHTML(row.name)}</span>${detail}</span>
      ${lock}
      ${kind ? `<span class="app__layer-kind">${ICONS[kind]}</span>` : ""}`;
    const cached = this.window.thumbnails.get(row.id);
    if (cached) item.querySelector(".app__thumbnail").getContext("2d").putImageData(cached, 0, 0);
    return item;
  }

  async loadThumbnails() {
    const win = this.window;
    const doc = win.doc;
    for (const row of this.info.rows) {
      if (row.kind !== "layer" || win.thumbnails.has(row.id)) continue;
      try {
        const { response, payload } = await win.engine.call("thumbnail", { doc, layer: row.id, size: 48 });
        if (doc !== win.doc) return;
        const image = new ImageData(48, 48);
        // Centred in the square.
        const ox = Math.floor((48 - response.width) / 2), oy = Math.floor((48 - response.height) / 2);
        for (let y = 0; y < response.height; y++) {
          image.data.set(payload.subarray(y * response.width * 4, (y + 1) * response.width * 4), ((y + oy) * 48 + ox) * 4);
        }
        win.thumbnails.set(row.id, image);
        this.list.querySelector(`[data-id="${row.id}"] .app__thumbnail`)?.getContext("2d").putImageData(image, 0, 0);
      } catch {
        // A layer without a thumbnail still shows its name.
      }
    }
  }

  /** Marks the picked row without building the list again. */
  highlight() {
    for (const item of this.list.children) {
      const chosen = item.dataset.id === this.window.selected;
      item.setAttribute("aria-selected", String(chosen));
      item.tabIndex = chosen ? 0 : -1;
      if (chosen) item.setAttribute("aria-current", "true");
      else item.removeAttribute("aria-current");
    }
  }

  renderActions() {
    const row = this.row();
    const layer = row?.kind === "layer" ? row : null;
    const set = (action, disabled) => { this.actions.querySelector(`[data-layer-action="${action}"]`).disabled = disabled; };
    set("duplicate", !layer);
    set("mergeDown", !layer?.canMergeDown);
    set("delete", !row || (layer ? this.layerCount() < 2 : this.layerCount() <= this.layersIn(row.id).length));
  }

  renderSettings() {
    const row = this.row();
    this.settings.hidden = !row;
    if (!row) return;
    this.settings.innerHTML = row.kind === "group" ? this.groupSettings(row) : this.layerSettings(row);
  }

  layerSettings(row) {
    const modes = this.info.blendModes.map((mode) => [mode.id, mode.label]);
    const locked = row.groupLocked;
    let html = heading(t("Layers.Section.Appearance"))
      + slider("opacity", t("Layers.Opacity"), 0, 100, Math.round(row.opacity * 100), percent(row.opacity));
    if (row.type !== "adjustment") html += slider("fillOpacity", t("Layers.Fill"), 0, 100, Math.round(row.fillOpacity * 100), percent(row.fillOpacity));
    html += popup("blendMode", t("Layers.BlendMode"), modes, row.blendMode)
      + toggle("locked", t("Layers.Lock"), row.locked)
      + toggle("clipped", t("Layers.ClipToBelow"), row.clipped, locked || (!row.clipped && !row.canClip));
    if (row.adjustment) html += this.adjustmentSettings(row.adjustment);
    html += heading(t("Mask.Title"));
    if (row.masked) {
      if (row.type !== "adjustment") html += toggle("editingMask", t("Mask.Edit"), this.window.editingMask);
      html += toggle("maskEnabled", t("Mask.Enabled"), row.maskEnabled)
        + button("maskActions", t("Mask.Actions"))
        + `<p class="ds-caption app__setting-wide app__setting-footer">${escapeHTML(t("Mask.Footer"))}</p>`;
    } else {
      html += button("addMask", this.info.selection ? t("Mask.AddFromSelection") : t("Mask.Add"), { disabled: locked });
    }
    return html;
  }

  adjustmentSettings(adjustment) {
    let html = heading(`${t("Layers.Section.Adjustment")} · ${adjustment.label}`);
    if (adjustment.amount) {
      const { value, min, max } = adjustment.amount;
      html += slider("amount", t("LayerFilters.Amount"), min * 100, max * 100, Math.round(value * 100), String(Math.round(value * 100)));
    }
    adjustment.parameters.forEach((parameter, index) => {
      const key = `parameter-${index}`;
      if (parameter.style === "toggle") html += toggle(key, parameter.label, parameter.value >= 0.5);
      else if (parameter.style === "choice") html += popup(key, parameter.label, parameter.choices.map((text, i) => [i, text]), Math.round(parameter.value));
      else {
        const scale = parameter.style === "percent" ? 100 : parameter.style === "decimal" ? 100 : 1;
        html += slider(key, parameter.label, parameter.min * scale, parameter.max * scale, Math.round(parameter.value * scale), parameterText(parameter, parameter.value));
      }
    });
    return html;
  }

  groupSettings(row) {
    const modes = [["passThrough", t("Web.Layers.PassThrough")], ...this.info.blendModes.map((mode) => [mode.id, mode.label])];
    return heading(t("Groups.Section"))
      + `<label class="ds-form__label" for="inspector-name">${escapeHTML(t("Layers.Rename.Placeholder"))}</label><input class="ds-text-input ds-text-input--xs" id="inspector-name" data-setting="name" value="${escapeHTML(row.name)}">`
      + slider("opacity", t("Layers.Opacity"), 0, 100, Math.round(row.opacity * 100), percent(row.opacity))
      + popup("blendMode", t("Layers.BlendMode"), modes, row.blendMode)
      + toggle("locked", t("Layers.Lock"), row.locked)
      + button("ungroup", t("Groups.Ungroup"))
      + button("mergeGroup", t("Groups.Merge"))
      + button("deleteGroup", t("Groups.Delete"), { disabled: this.layerCount() <= this.layersIn(row.id).length, destructive: true });
  }

  layerCount() {
    return this.info.rows.filter((row) => row.kind === "layer").length;
  }

  /** The layers inside a group, however deep, as the list shows them. */
  layersIn(groupID) {
    const rows = this.info.rows;
    const start = rows.findIndex((row) => row.id === groupID);
    if (start < 0) return [];
    const depth = rows[start].depth;
    const inside = [];
    for (let i = start + 1; i < rows.length && rows[i].depth > depth; i++) if (rows[i].kind === "layer") inside.push(rows[i]);
    // A closed group's layers aren't listed; count it as holding at least one.
    return inside.length || rows[start].expanded ? inside : [null];
  }

  // ------------------------------------------------------------ Settings

  settingMoved(event) {
    const input = event.target;
    if (input.type !== "range") return;
    const shows = this.settings.querySelector(`[data-shows="${input.dataset.setting}"]`);
    if (!shows) return;
    const key = input.dataset.setting;
    const value = Number(input.value);
    if (key.startsWith("parameter-")) {
      const parameter = this.row().adjustment.parameters[Number(key.slice(10))];
      const scale = parameter.style === "percent" || parameter.style === "decimal" ? 100 : 1;
      shows.textContent = parameterText(parameter, value / scale);
    } else {
      shows.textContent = key === "amount" ? String(value) : `${value}%`;
    }
  }

  settingChanged(event) {
    const input = event.target;
    const key = input.dataset.setting;
    if (!key) return;
    const row = this.row();
    const value = input.type === "checkbox" ? input.checked : input.value;
    switch (key) {
      case "opacity":
      case "fillOpacity": return this.window.update({ [key]: Number(value) / 100 });
      case "blendMode": return this.window.update({ blendMode: value });
      case "locked": return this.window.update({ locked: value });
      case "name": return value.trim() ? this.window.update({ name: value.trim() }) : this.renderSettings();
      case "clipped": return this.layers({ action: "clip", clipped: value });
      case "maskEnabled": return this.layers({ action: "enableMask", enabled: value });
      case "editingMask":
        this.window.editingMask = value;
        this.render();
        return undefined;
      case "amount": return this.window.update({ amount: Number(value) / 100 });
      default: {
        if (!key.startsWith("parameter-")) return undefined;
        const index = Number(key.slice(10));
        const parameter = row.adjustment.parameters[index];
        let number = input.type === "checkbox" ? (value ? 1 : 0) : Number(value);
        if (parameter.style === "percent" || parameter.style === "decimal") number /= 100;
        return this.window.update({ parameter: index, value: number });
      }
    }
  }

  command(name, target) {
    switch (name) {
      case "addMask":
        this.window.editingMask = true;
        return this.layers({ action: "addMask" });
      case "maskActions": return openMenu(this.maskItems(), target);
      case "ungroup":
      case "mergeGroup":
      case "deleteGroup": return this.layers({ action: name, group: this.window.selected });
      default: return undefined;
    }
  }

  maskItems() {
    const row = this.row();
    const selected = Boolean(this.info.selection);
    const items = [
      { label: t("Mask.HideSelection"), disabled: !selected, action: () => this.layers({ action: "maskSelection", reveal: false }) },
      { label: t("Mask.RevealSelection"), disabled: !selected, action: () => this.layers({ action: "maskSelection", reveal: true }) },
      { label: t("Mask.Invert"), action: () => this.layers({ action: "invertMask" }) },
    ];
    // An adjustment layer is nothing but its mask.
    if (row?.type !== "adjustment") {
      items.push(
        { separator: true },
        { label: t("Mask.Apply"), disabled: row?.groupLocked, action: () => { this.window.editingMask = false; this.layers({ action: "applyMask" }); } },
        { label: t("Mask.Delete"), action: () => { this.window.editingMask = false; this.layers({ action: "deleteMask" }); } },
      );
    }
    return items;
  }

  // ------------------------------------------------------------ Actions

  perform(action, anchor) {
    const row = this.row();
    switch (action) {
      case "add": return openMenu(this.addItems(), anchor);
      case "more": return openMenu(this.moreItems(), anchor);
      case "duplicate": return this.layers({ action: "duplicate" });
      case "mergeDown": return this.layers({ action: "mergeDown" });
      case "delete":
        if (row?.kind === "group") return this.layers({ action: "deleteGroup", group: row.id });
        return this.layers({ action: "delete" });
      default: return undefined;
    }
  }

  addItems() {
    const adjustments = [];
    for (const group of this.info.adjustmentKinds) {
      if (adjustments.length) adjustments.push({ separator: true });
      for (const kind of group) adjustments.push({ label: kind.label, action: () => this.layers({ action: "addAdjustment", kind: kind.id }) });
    }
    return [
      { label: t("Layers.NewLayer"), action: () => this.layers({ action: "add" }) },
      { label: t("Layers.NewAdjustment"), submenu: adjustments },
      { separator: true },
      { label: t("Layers.ImportFiles"), action: () => this.importFile() },
      { label: t("Layers.Paste"), action: () => this.paste() },
    ];
  }

  moreItems() {
    const layer = this.row()?.kind === "layer";
    return [
      { label: t("Layers.Copy"), disabled: !layer, action: () => this.copy() },
      { label: t("Groups.Group"), disabled: !layer, action: () => this.layers({ action: "group" }) },
      { label: t("Layers.Flatten"), disabled: this.layerCount() < 2, action: () => this.layers({ action: "flatten" }) },
    ];
  }

  rowItems(row) {
    if (row.kind === "group") {
      return [
        { label: t("Layers.Rename"), action: () => this.rename(row) },
        { separator: true },
        { label: t("Groups.Ungroup"), action: () => this.layers({ action: "ungroup", group: row.id }) },
        { label: t("Groups.Merge"), action: () => this.layers({ action: "mergeGroup", group: row.id }) },
        { separator: true },
        { label: t("Groups.Delete"), disabled: this.layerCount() <= this.layersIn(row.id).length, action: () => this.layers({ action: "deleteGroup", group: row.id }) },
      ];
    }
    const layers = this.info.rows.filter((r) => r.kind === "layer");
    const at = { layer: row.id };
    const items = [
      { label: t("Layers.Rename"), action: () => this.rename(row) },
      { label: t("Layers.Duplicate"), action: () => this.layers({ ...at, action: "duplicate" }) },
      { label: row.locked ? t("Layers.Unlock") : t("Layers.Lock"), action: () => this.window.update({ locked: !row.locked }, row.id) },
      { separator: true },
      { label: t("Layers.MoveUp"), disabled: layers[0]?.id === row.id, action: () => this.layers({ ...at, action: "moveBy", offset: 1 }, { select: false }) },
      { label: t("Layers.MoveDown"), disabled: layers.at(-1)?.id === row.id, action: () => this.layers({ ...at, action: "moveBy", offset: -1 }, { select: false }) },
      { label: t("Layers.MergeDown"), disabled: !row.canMergeDown, action: () => this.layers({ ...at, action: "mergeDown" }) },
      row.clipped
        ? { label: t("Layers.ReleaseClipping"), action: () => this.layers({ ...at, action: "clip", clipped: false }, { select: false }) }
        : { label: t("Layers.ClipToBelow"), disabled: !row.canClip, action: () => this.layers({ ...at, action: "clip", clipped: true }, { select: false }) },
    ];
    if (["text", "vector", "smart"].includes(row.type)) items.push({ label: t("Layers.Rasterize"), action: () => this.layers({ ...at, action: "rasterize" }, { select: false }) });
    items.push({ separator: true }, { label: t("Groups.Group"), action: () => this.layers({ ...at, action: "group" }) });
    if (this.info.groups.length) {
      items.push({
        label: t("Groups.MoveTo"),
        submenu: [
          { label: t("Groups.NoGroup"), disabled: !row.groupID, action: () => this.layers({ ...at, action: "moveToGroup", group: null }, { select: false }) },
          { separator: true },
          ...this.info.groups.map((group) => ({ label: group.name, disabled: row.groupID === group.id, action: () => this.layers({ ...at, action: "moveToGroup", group: group.id }, { select: false }) })),
        ],
      });
    }
    items.push({ separator: true }, { label: t("Layers.Delete"), disabled: layers.length < 2, action: () => this.layers({ ...at, action: "delete" }) });
    return items;
  }

  showRowMenu(id, point) {
    const row = this.row(id);
    if (!row) return;
    if (id !== this.window.selected) this.window.select(id);
    openMenu(this.rowItems(row), point, { placement: "point" });
  }

  async rename(row) {
    const name = await this.window.askName(row.name);
    if (name && name.trim() && name.trim() !== row.name) this.window.update({ name: name.trim() }, row.id);
  }

  async importFile() {
    const chosen = await chooseFile();
    if (!chosen) return;
    await this.addPicture(chosen.file, chosen.file.name);
  }

  async paste() {
    try {
      for (const item of await navigator.clipboard.read()) {
        const type = item.types.find((kind) => kind.startsWith("image/"));
        if (type) return this.addPicture(await item.getType(type), "");
      }
    } catch {
      // Refused, or nothing readable: said below.
    }
    this.window.alert(t("Error.NothingToPaste"));
    return undefined;
  }

  async addPicture(blob, name) {
    let bytes;
    try {
      bytes = await decodePicture(blob);
    } catch {
      this.window.alert(t("Error.ImportFailed"));
      return;
    }
    await this.window.edit("layers", { action: "addImage", name }, { all: true, payload: bytes });
  }

  async copy() {
    const win = this.window;
    const size = Math.max(this.info.width, this.info.height);
    try {
      const { response, payload } = await win.engine.call("thumbnail", { doc: win.doc, layer: win.selected, size: Math.min(size, 8192) });
      const canvas = new OffscreenCanvas(response.width, response.height);
      canvas.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(payload.buffer, payload.byteOffset, payload.byteLength), response.width, response.height), 0, 0);
      const blob = await canvas.convertToBlob({ type: "image/png" });
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
    } catch (error) {
      win.alert(error.message);
    }
  }

  // ------------------------------------------------------------ The list

  clicked(event) {
    if (this.suppressClick) {
      this.suppressClick = false;
      return;
    }
    const item = event.target.closest(".app__layer");
    if (!item) return;
    const row = this.row(item.dataset.id);
    if (event.target.closest("[data-toggle]")) return this.window.update({ visible: !row.visible }, row.id);
    if (event.target.closest("[data-expand]")) return this.window.update({ expanded: !row.expanded }, row.id, { render: false });
    if (event.target.closest("[data-mask]")) return this.window.select(row.id, { mask: true });
    return this.window.select(row.id);
  }

  doubleClicked(event) {
    const item = event.target.closest(".app__layer");
    if (!item || event.target.closest("button")) return;
    this.rename(this.row(item.dataset.id));
  }

  key(event) {
    const rows = this.info?.rows ?? [];
    const index = rows.findIndex((row) => row.id === this.window.selected);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = rows[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), rows.length - 1)];
      if (next) this.window.select(next.id, { focus: true });
    } else if (event.key === " ") {
      event.preventDefault();
      const row = this.row();
      if (row) this.window.update({ visible: !row.visible }, row.id);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const row = this.row();
      if (row) this.rename(row);
    } else if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      event.stopPropagation();
      this.perform("delete");
    }
  }

  // A long press opens the row's menu on touch screens; a mouse drag moves a layer up or down the stack.
  pointerDown(event) {
    const item = event.target.closest(".app__layer");
    if (!item || event.target.closest("button") || (event.pointerType === "mouse" && event.button !== 0)) return;
    const start = { x: event.clientX, y: event.clientY };
    const id = item.dataset.id;
    const row = this.row(id);
    let timer = 0;
    if (event.pointerType !== "mouse") {
      timer = setTimeout(() => {
        timer = 0;
        this.suppressClick = true;
        this.showRowMenu(id, start);
      }, LONG_PRESS);
    }
    let dragging = false;
    const move = (e) => {
      const far = Math.hypot(e.clientX - start.x, e.clientY - start.y) > 6;
      if (far && timer) {
        clearTimeout(timer);
        timer = 0;
      }
      if (event.pointerType !== "mouse" || row?.kind !== "layer") return;
      if (!dragging && far) {
        dragging = true;
        item.classList.add("is-dragging");
      }
      if (dragging) this.showDrop(e.clientY);
    };
    const end = (e) => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
      clearTimeout(timer);
      if (!dragging) return;
      item.classList.remove("is-dragging");
      this.suppressClick = true;
      const to = this.showDrop(e.clientY);
      this.list.querySelector(".app__drop")?.remove();
      const from = this.info.rows.findIndex((r) => r.id === id);
      if (e.type === "pointerup" && to !== from && to !== from + 1) this.layers({ action: "moveRow", from, to }, { select: false });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
  }

  /** Where a dragged row would land at `y`, as an index between rows, marked with a line. */
  showDrop(y) {
    const items = [...this.list.querySelectorAll(".app__layer")];
    let to = items.length;
    for (const [index, item] of items.entries()) {
      const rect = item.getBoundingClientRect();
      if (y < rect.top + rect.height / 2) {
        to = index;
        break;
      }
    }
    let line = this.list.querySelector(".app__drop");
    if (!line) {
      line = document.createElement("div");
      line.className = "app__drop";
      this.list.append(line);
    }
    const listRect = this.list.getBoundingClientRect();
    const edge = to < items.length ? items[to].getBoundingClientRect().top : items.at(-1).getBoundingClientRect().bottom;
    line.style.top = `${edge - listRect.top + this.list.scrollTop - 1}px`;
    return to;
  }
}
