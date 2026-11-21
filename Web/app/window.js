// Easel's window: the menu bar and toolbar, the canvas, the Layers inspector
// and the status bar, over one document at a time.

import { attachMenuBar, attachToolbarOverflow, openMenu } from "../design/menus.js";
import { dismissSheet } from "../design/sheets.js";
import { t, language } from "./i18n.js";
import { chooseFile, choosePackage, droppedDocument, bytesForEngine, readHandle, saveFile } from "./files.js";
import * as storage from "./storage.js";

const icon = (path, extra = "") => `<svg class="ds-icon" viewBox="0 0 16 16" aria-hidden="true"${extra}>${path}</svg>`;
const ICONS = {
  eye: icon('<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z" fill="none" stroke="currentColor"/><circle cx="8" cy="8" r="2" fill="none" stroke="currentColor"/>'),
  eyeOff: icon('<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z" fill="none" stroke="currentColor" opacity=".45"/><path d="M2.5 13.5l11-11" stroke="currentColor"/>'),
  folder: icon('<path d="M1.5 4.5v8h13v-7h-6l-1.5-1.5h-5.5z" fill="none" stroke="currentColor"/>'),
  chevron: icon('<path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.5"/>'),
  zoomIn: icon('<circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor"/><path d="M10.5 10.5l3.5 3.5M5 7h4M7 5v4" stroke="currentColor"/>'),
  zoomOut: icon('<circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor"/><path d="M10.5 10.5l3.5 3.5M5 7h4" stroke="currentColor"/>'),
  fit: icon('<path d="M2 6V2h4M10 2h4v4M14 10v4h-4M6 14H2v-4" fill="none" stroke="currentColor"/>'),
  open: icon('<path d="M1.5 4.5v8h13v-7h-6l-1.5-1.5h-5.5z" fill="none" stroke="currentColor"/>'),
  share: icon('<path d="M8 10V2M5 5l3-3 3 3M3.5 7.5v6h9v-6" fill="none" stroke="currentColor"/>'),
  text: icon('<path d="M3 3.5h10M8 3.5v10" stroke="currentColor" stroke-width="1.5"/>'),
  vector: icon('<path d="M3 13C5 5 11 11 13 3" fill="none" stroke="currentColor"/><rect x="1.5" y="11.5" width="3" height="3" fill="none" stroke="currentColor"/><rect x="11.5" y="1.5" width="3" height="3" fill="none" stroke="currentColor"/>'),
  adjustment: icon('<circle cx="8" cy="8" r="6" fill="none" stroke="currentColor"/><path d="M8 2a6 6 0 0 1 0 12z" fill="currentColor"/>'),
  picture: icon('<rect x="1.5" y="2.5" width="13" height="11" fill="none" stroke="currentColor"/><path d="M1.5 11l4-4 3 3 2-2 4 4" fill="none" stroke="currentColor"/><circle cx="11" cy="5.5" r="1" fill="currentColor"/>'),
  close: icon('<path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.5"/>'),
  smart: icon('<rect x="2.5" y="2.5" width="11" height="11" fill="none" stroke="currentColor"/><path d="M5 11l2.5-3 2 2 1.5-2" fill="none" stroke="currentColor"/>'),
};

const ZOOMS = [0.05, 0.0833, 0.125, 0.1667, 0.25, 0.3333, 0.5, 0.6667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32];
const DISPLAY_LIMIT = 4096;
const RECENT_LIMIT = 12;

const escapeHTML = (text) => String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const isMac = /Mac|iPhone|iPad/.test(navigator.platform);
const shortcut = (key) => (isMac ? `⌘${key}` : `Ctrl+${key}`);

export class EaselWindow {
  constructor(root, engine) {
    this.root = root;
    this.engine = engine;
    this.doc = null;
    this.info = null;
    this.name = "";
    this.selected = null;
    this.zoom = 1;
    this.renderToken = 0;
    this.thumbnails = new Map();
    this.build();
  }

  // ------------------------------------------------------------ Building

  build() {
    this.root.innerHTML = `
      <div class="ds-menu-bar"></div>
      <div class="ds-toolbar app__toolbar">
        <div class="ds-toolbar__title" data-overflow="never"><span class="app__title">Easel</span><span class="ds-toolbar__subtitle app__subtitle"></span></div>
        <div class="ds-toolbar__spacer"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="zoomOut" title="${escapeHTML(t("Menu.ZoomOut"))}" aria-label="${escapeHTML(t("Menu.ZoomOut"))}" disabled>${ICONS.zoomOut}</button>
        <button class="ds-button ds-button--ghost app__zoom ds-numeric" data-action="actual" title="${escapeHTML(t("Canvas.ActualSize"))}" disabled>100%</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="zoomIn" title="${escapeHTML(t("Menu.ZoomIn"))}" aria-label="${escapeHTML(t("Menu.ZoomIn"))}" disabled>${ICONS.zoomIn}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="fit" title="${escapeHTML(t("Canvas.FitToScreen"))}" aria-label="${escapeHTML(t("Canvas.FitToScreen"))}" disabled>${ICONS.fit}</button>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="export" title="${escapeHTML(t("Menu.Export"))}" aria-label="${escapeHTML(t("Menu.Export"))}" disabled>${ICONS.share}</button>
        <button class="ds-button ds-button--primary ds-button--xs app__update" data-overflow="never">${escapeHTML(t("Web.Update.Button"))}</button>
      </div>
      <div class="ds-window__content app__content">
        <div class="app__start"></div>
        <div class="app__viewport" hidden><div class="app__stage"><canvas class="app__canvas"></canvas></div></div>
        <div class="app__busy" hidden><div class="ds-spinner"></div><span class="ds-caption"></span></div>
      </div>
      <aside class="ds-inspector app__inspector" aria-label="${escapeHTML(t("Web.Layers.Title"))}" hidden>
        <div class="ds-inspector__body app__layers-body">
          <h2 class="ds-heading-compact app__layers-title">${escapeHTML(t("Web.Layers.Title"))}</h2>
          <div class="ds-source-list app__layers" role="listbox" aria-label="${escapeHTML(t("Web.Layers.Title"))}"></div>
        </div>
        <div class="app__layer-settings">
          <label class="ds-form__label" for="layer-opacity">${escapeHTML(t("Layers.Opacity"))}</label>
          <div class="ds-slider"><input id="layer-opacity" type="range" min="0" max="100" step="1"><span class="ds-numeric app__opacity-value"></span></div>
          <label class="ds-form__label" for="layer-blend">${escapeHTML(t("Layers.BlendMode"))}</label>
          <span class="ds-popup ds-popup--xs"><select class="ds-popup__select" id="layer-blend"></select><svg class="ds-icon ds-popup__chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.5"/></svg></span>
        </div>
      </aside>
      <div class="ds-status-bar app__status" hidden>
        <span class="app__status-size ds-numeric"></span><span class="app__status-layers ds-numeric"></span>
        <span class="ds-status-bar__spacer"></span><span class="app__status-note">${escapeHTML(t("Web.Status.Preview"))}</span>
      </div>`;
    const $ = (selector) => this.root.querySelector(selector);
    this.toolbar = $(".app__toolbar");
    this.title = $(".app__title");
    this.subtitle = $(".app__subtitle");
    this.start = $(".app__start");
    this.viewport = $(".app__viewport");
    this.stage = $(".app__stage");
    this.canvas = $(".app__canvas");
    this.busy = $(".app__busy");
    this.inspector = $(".app__inspector");
    this.layers = $(".app__layers");
    this.settings = $(".app__layer-settings");
    this.opacity = $("#layer-opacity");
    this.opacityValue = $(".app__opacity-value");
    this.blend = $("#layer-blend");
    this.status = $(".app__status");
    this.zoomLabel = $(".app__zoom");
    this.updateButton = $(".app__update");

    this.menuBar = attachMenuBar($(".ds-menu-bar"), this.menus(), { label: "Easel" });
    attachToolbarOverflow(this.toolbar);

    this.root.addEventListener("click", (event) => {
      const button = event.target.closest("[data-action]");
      if (button && !button.disabled) this.perform(button.dataset.action);
    });
    this.opacity.addEventListener("input", () => {
      this.opacityValue.textContent = `${this.opacity.value}%`;
    });
    this.opacity.addEventListener("change", () => this.update({ opacity: Number(this.opacity.value) / 100 }));
    this.blend.addEventListener("change", () => this.update({ blendMode: this.blend.value }));
    this.layers.addEventListener("click", (event) => this.layerClicked(event));
    this.layers.addEventListener("keydown", (event) => this.layerKey(event));
    this.viewport.addEventListener("wheel", (event) => this.wheel(event), { passive: false });
    window.addEventListener("keydown", (event) => this.keyDown(event));
    window.addEventListener("resize", () => this.doc && this.layout());
    this.watchDrops();
    this.watchLaunches();
  }

  menus() {
    const has = () => this.doc !== null;
    const self = this;
    return [
      {
        label: t("Menu.File"),
        get items() {
          return [
            { label: t("Web.Menu.NewImage"), shortcut: shortcut("N"), action: () => self.perform("new") },
            { label: t("Menu.Open"), shortcut: shortcut("O"), action: () => self.perform("open") },
            { label: t("Web.Menu.OpenPackage"), action: () => self.perform("openPackage") },
            { label: t("Web.Menu.OpenSample"), action: () => self.perform("sample") },
            { separator: true },
            { label: t("Menu.Export"), disabled: !has(), submenu: self.exportItems() },
            { separator: true },
            { label: t("Menu.Close"), shortcut: shortcut("W"), disabled: !has(), action: () => self.perform("close") },
          ];
        },
      },
      {
        label: t("Menu.View"),
        get items() {
          return [
            { label: t("Menu.ZoomIn"), shortcut: shortcut("+"), disabled: !has(), action: () => self.perform("zoomIn") },
            { label: t("Menu.ZoomOut"), shortcut: shortcut("−"), disabled: !has(), action: () => self.perform("zoomOut") },
            { label: t("Canvas.ActualSize"), shortcut: shortcut("1"), disabled: !has(), action: () => self.perform("actual") },
            { label: t("Canvas.FitToScreen"), shortcut: shortcut("0"), disabled: !has(), action: () => self.perform("fit") },
          ];
        },
      },
      {
        label: t("Menu.Help"),
        get items() {
          return [{ label: t("Menu.About %@", "Easel"), action: () => self.about() }];
        },
      },
    ];
  }

  exportItems() {
    return [
      { label: t("Export.PNG"), action: () => this.export("png") },
      { label: t("Export.JPEG"), action: () => this.export("jpeg") },
      { label: t("Export.PSD"), action: () => this.export("psd") },
      { label: t("Export.SVG"), action: () => this.export("svg") },
      { label: t("Export.Easel"), action: () => this.export("easel") },
    ];
  }

  perform(action) {
    switch (action) {
      case "open": return this.openChosen();
      case "openPackage": return this.openPackage();
      case "new": return this.newImage();
      case "sample": return this.load(() => this.engine.call("sample"), "Easel");
      case "close": return this.close();
      case "zoomIn": return this.setZoom(ZOOMS.find((z) => z > this.zoom + 1e-6) ?? this.zoom);
      case "zoomOut": return this.setZoom([...ZOOMS].reverse().find((z) => z < this.zoom - 1e-6) ?? this.zoom);
      case "actual": return this.setZoom(1);
      case "fit": return this.setZoom(this.fitZoom());
      case "export": return this.showExportMenu();
      default: return undefined;
    }
  }

  showStart() {
    this.root.querySelector(".app__loading")?.remove();
    this.showDocument(false);
    this.refreshRecents();
  }

  async refreshRecents() {
    this.recents = await storage.recentDocuments();
    if (!this.start.hidden) this.renderStart();
  }

  renderStart() {
    const recents = this.recents ?? [];
    const relative = new Intl.RelativeTimeFormat(language, { numeric: "auto" });
    const when = (time) => {
      const minutes = Math.round((time - Date.now()) / 60000);
      if (Math.abs(minutes) < 60) return relative.format(minutes, "minute");
      const hours = Math.round(minutes / 60);
      if (Math.abs(hours) < 24) return relative.format(hours, "hour");
      return new Intl.DateTimeFormat(language, { dateStyle: "medium" }).format(time);
    };
    this.start.innerHTML = `
      <div class="app__start-inner">
        <h1 class="ds-heading-04">Easel</h1>
        <p class="ds-body app__start-intro">${escapeHTML(t("Web.Start.Intro"))}</p>
        <div class="app__start-actions">
          <button class="ds-button ds-button--primary" data-action="new">${escapeHTML(t("Web.Start.New"))}</button>
          <button class="ds-button ds-button--bordered" data-action="open">${escapeHTML(t("Menu.Open"))}</button>
        </div>
        <h2 class="ds-heading-compact app__start-heading">${escapeHTML(t("Menu.OpenRecent"))}</h2>
        ${recents.length ? `<table class="ds-table app__recents"><tbody>
          ${recents.map((record) => `<tr data-id="${escapeHTML(record.id)}" tabindex="0">
            <td>${record.isPackage ? ICONS.folder : ICONS.picture} <span>${escapeHTML(record.name)}</span></td>
            <td class="ds-numeric app__recent-date">${escapeHTML(when(record.openedAt))}</td>
            <td class="app__recent-remove"><button class="ds-button ds-button--ghost ds-button--icon ds-button--xs" data-remove="${escapeHTML(record.id)}" aria-label="${escapeHTML(t("Web.Start.Remove"))}" title="${escapeHTML(t("Web.Start.Remove"))}">${ICONS.close}</button></td>
          </tr>`).join("")}</tbody></table>`
        : `<p class="ds-caption">${escapeHTML(t("Web.Start.NoRecent"))}</p>`}
      </div>`;
    for (const row of this.start.querySelectorAll("tr[data-id]")) {
      const record = recents.find((entry) => entry.id === row.dataset.id);
      row.addEventListener("click", (event) => {
        if (event.target.closest("[data-remove]")) return;
        this.openRecord(record);
      });
      row.addEventListener("keydown", (event) => event.key === "Enter" && this.openRecord(record));
    }
    for (const button of this.start.querySelectorAll("[data-remove]")) {
      button.addEventListener("click", async () => {
        await storage.removeRecord(button.dataset.remove);
        this.refreshRecents();
      });
    }
  }

  showDocument(shown) {
    this.start.hidden = shown;
    this.viewport.hidden = !shown;
    this.inspector.hidden = !shown;
    this.status.hidden = !shown;
    for (const button of this.toolbar.querySelectorAll("[data-action]")) button.disabled = !shown;
    this.root.classList.toggle("is-empty", !shown);
    if (!shown) {
      this.renderStart();
      this.title.textContent = "Easel";
      this.subtitle.textContent = "";
      document.title = "Easel";
    }
  }

  // ------------------------------------------------------------ Documents

  async openChosen() {
    const chosen = await chooseFile();
    if (chosen) await this.openFile(chosen.file, { handle: chosen.handle });
  }

  async openPackage() {
    const chosen = await choosePackage();
    if (chosen) await this.openPackageBytes(chosen.name, chosen.bytes);
  }

  async openPackageBytes(name, bytes, record = null) {
    await this.load(() => this.engine.call("open", { name, package: true }, bytes.slice()), name, { bytes: record ? null : bytes, isPackage: true, record });
  }

  /** Opens a file, remembering it in Open Recent by its handle, or else by a copy of it. */
  async openFile(file, { handle = null, record = null } = {}) {
    const copy = handle || record?.kept ? null : new Uint8Array(await file.arrayBuffer());
    await this.load(async () => {
      let bytes;
      try {
        bytes = await bytesForEngine(file);
      } catch {
        throw new Error(t("Web.Error.Picture"));
      }
      return this.engine.call("open", { name: file.name }, bytes);
    }, file.name, { handle, bytes: copy, record });
  }

  async openRecord(record) {
    try {
      if (record.handle) {
        const file = await readHandle(record.handle);
        if (file) await this.openFile(file, { handle: record.handle, record });
        return;
      }
      const bytes = record.kept ? await storage.readCopy(record.id) : null;
      if (!bytes) {
        this.alert(t("Web.Error.Missing %@", record.name));
        return;
      }
      if (record.isPackage) await this.openPackageBytes(record.name, bytes, record);
      else await this.openFile(new File([bytes], record.name), { record });
    } catch (error) {
      this.alert(t("Web.Error.Open %@ %@", record.name, error.message));
    }
  }

  /** Puts a document at the top of Open Recent. */
  async remember(name, { handle = null, bytes = null, isPackage = false, record = null }) {
    const recents = await storage.recentDocuments();
    let existing = record;
    if (!existing && handle) {
      for (const entry of recents) {
        if (entry.handle && (await entry.handle.isSameEntry?.(handle))) {
          existing = entry;
          break;
        }
      }
    }
    // Without a handle there's no telling two files apart but by name: the newer copy replaces the older.
    if (!existing && !handle) existing = recents.find((entry) => !entry.handle && entry.name === name && Boolean(entry.isPackage) === isPackage) ?? null;
    const entry = { id: existing?.id ?? crypto.randomUUID(), name, openedAt: Date.now(), isPackage: isPackage || Boolean(existing?.isPackage) };
    if (handle) {
      entry.handle = handle;
      if (existing?.kept) await storage.removeCopy(entry.id);
    } else if (bytes) {
      entry.kept = await storage.writeCopy(entry.id, bytes);
    } else {
      entry.kept = Boolean(existing?.kept);
    }
    await storage.saveRecord(entry);
    for (const old of recents.filter((r) => r.id !== entry.id).slice(RECENT_LIMIT - 1)) await storage.removeRecord(old.id);
    storage.persist();
  }

  /** Runs `request`, which makes a document, and shows it. */
  async load(request, name, remembering = null) {
    this.setBusy(t("Web.Opening"));
    try {
      const { response } = await request();
      if (this.doc !== null) this.engine.call("close", { doc: this.doc }).catch(() => {});
      this.doc = response.doc;
      this.name = name.replace(/\.[^.]+$/, "");
      this.info = response;
      this.selected = response.rows.find((row) => row.kind === "layer")?.id ?? null;
      this.thumbnails.clear();
      this.title.textContent = this.name;
      document.title = `${this.name} – Easel`;
      this.showDocument(true);
      this.showInfo();
      this.zoom = this.fitZoom();
      this.layout();
      await this.render();
      if (remembering) this.remember(name, remembering).catch(() => {});
    } catch (error) {
      this.alert(t("Web.Error.Open %@ %@", name, error.message));
    } finally {
      this.setBusy(null);
    }
  }

  close() {
    if (this.doc === null) return;
    this.engine.call("close", { doc: this.doc }).catch(() => {});
    this.doc = null;
    this.info = null;
    this.showStart();
  }

  newImage() {
    const backdrop = this.sheet(`
      <form class="ds-sheet" role="dialog" aria-labelledby="new-title">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="new-title">${escapeHTML(t("Web.New.Title"))}</h2>
          <div class="ds-form app__new-form">
            <label class="ds-form__label" for="new-width">${escapeHTML(t("ImageSize.Width"))}</label>
            <span class="ds-form__control"><input class="ds-text-input ds-numeric" id="new-width" type="number" min="1" max="8192" value="2048" required> ${escapeHTML(t("ImageSize.Pixels"))}</span>
            <label class="ds-form__label" for="new-height">${escapeHTML(t("ImageSize.Height"))}</label>
            <span class="ds-form__control"><input class="ds-text-input ds-numeric" id="new-height" type="number" min="1" max="8192" value="1536" required> ${escapeHTML(t("ImageSize.Pixels"))}</span>
            <span class="ds-form__label">${escapeHTML(t("Web.New.Background"))}</span>
            <span class="ds-form__control"><span class="ds-segmented" role="radiogroup">
              <button type="button" class="ds-segmented__segment" role="radio" aria-checked="true" data-fill="white">${escapeHTML(t("Color.White"))}</button>
              <button type="button" class="ds-segmented__segment" role="radio" aria-checked="false" data-fill="clear">${escapeHTML(t("LayerFilters.Transparent"))}</button>
            </span></span>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Web.New.Create"))}</button>
        </div>
      </form>`);
    const form = backdrop.querySelector("form");
    let fill = "white";
    form.addEventListener("click", (event) => {
      const segment = event.target.closest("[data-fill]");
      if (!segment) return;
      fill = segment.dataset.fill;
      for (const s of form.querySelectorAll("[data-fill]")) s.setAttribute("aria-checked", String(s === segment));
    });
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const width = Number(form.querySelector("#new-width").value);
      const height = Number(form.querySelector("#new-height").value);
      dismissSheet(backdrop);
      this.load(() => this.engine.call("new", { width, height, fill: fill === "white" ? [1, 1, 1, 1] : [0, 0, 0, 0] }), t("Export.DefaultName"));
    });
    form.querySelector("#new-width").select();
  }

  async export(format) {
    if (this.doc === null) return;
    const kinds = {
      png: ["png", "image/png"], jpeg: ["jpg", "image/jpeg"], psd: ["psd", "image/vnd.adobe.photoshop"],
      svg: ["svg", "image/svg+xml"], easel: ["easel.zip", "application/zip"],
    };
    const [ext, type] = kinds[format];
    this.setBusy(t("Web.Exporting"));
    try {
      const { payload } = await this.engine.call("export", { doc: this.doc, format });
      this.setBusy(null);
      await saveFile(payload, `${this.name}.${ext}`, type);
    } catch (error) {
      this.alert(t("Web.Error.Export %@", error.message));
    } finally {
      this.setBusy(null);
    }
  }

  showExportMenu() {
    openMenu(this.exportItems(), this.toolbar.querySelector('[data-action="export"]'));
  }

  // ------------------------------------------------------------ Canvas

  fitZoom() {
    if (!this.info) return 1;
    const width = this.viewport.clientWidth || this.root.clientWidth - 280;
    const height = this.viewport.clientHeight || this.root.clientHeight - 120;
    const fit = Math.min((width - 64) / this.info.width, (height - 64) / this.info.height);
    return Math.max(0.02, Math.min(1, fit));
  }

  setZoom(zoom, anchor = null) {
    if (!this.info) return;
    const viewport = this.viewport;
    const point = anchor ?? { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 };
    const before = this.canvasPoint(point);
    this.zoom = Math.min(32, Math.max(0.02, zoom));
    this.layout();
    // Keep the point under the pointer (or the middle) where it was.
    const rect = this.canvas.getBoundingClientRect();
    const viewRect = viewport.getBoundingClientRect();
    viewport.scrollLeft += rect.left - viewRect.left + before.x * this.zoom - point.x;
    viewport.scrollTop += rect.top - viewRect.top + before.y * this.zoom - point.y;
  }

  /** A point in the viewport as canvas pixels. */
  canvasPoint(point) {
    const rect = this.canvas.getBoundingClientRect();
    const viewRect = this.viewport.getBoundingClientRect();
    return { x: (point.x + viewRect.left - rect.left) / this.zoom, y: (point.y + viewRect.top - rect.top) / this.zoom };
  }

  layout() {
    const { width, height } = this.info;
    const w = width * this.zoom, h = height * this.zoom;
    this.canvas.style.width = `${w}px`;
    this.canvas.style.height = `${h}px`;
    // Room to scroll the picture's edges to the middle when it's larger than the window.
    const padX = Math.max(32, (this.viewport.clientWidth - w) / 2);
    const padY = Math.max(32, (this.viewport.clientHeight - h) / 2);
    this.stage.style.padding = `${padY}px ${padX}px`;
    this.canvas.classList.toggle("is-pixelated", this.zoom > 2);
    this.zoomLabel.textContent = t("Web.Zoom %lld", Math.round(this.zoom * 100));
  }

  wheel(event) {
    if (!event.ctrlKey && !event.metaKey) return;
    event.preventDefault();
    const viewRect = this.viewport.getBoundingClientRect();
    this.setZoom(this.zoom * Math.exp(-event.deltaY * 0.01), { x: event.clientX - viewRect.left, y: event.clientY - viewRect.top });
  }

  async render() {
    if (this.doc === null) return;
    const token = ++this.renderToken;
    const maxSize = Math.min(Math.max(this.info.width, this.info.height), DISPLAY_LIMIT);
    const { response, payload } = await this.engine.call("render", { doc: this.doc, maxSize });
    if (token !== this.renderToken) return;
    this.canvas.width = response.width;
    this.canvas.height = response.height;
    const context = this.canvas.getContext("2d");
    context.putImageData(new ImageData(new Uint8ClampedArray(payload.buffer, payload.byteOffset, payload.byteLength), response.width, response.height), 0, 0);
  }

  // ------------------------------------------------------------ Layers

  showInfo() {
    const info = this.info;
    const number = new Intl.NumberFormat(language);
    this.root.querySelector(".app__status-size").textContent = t("Web.Status.Size %lld %lld", number.format(Math.round(info.width)), number.format(Math.round(info.height)));
    this.root.querySelector(".app__status-layers").textContent = t("Web.Status.Layers %lld", info.rows.filter((row) => row.kind === "layer").length);
    this.subtitle.textContent = this.root.querySelector(".app__status-size").textContent;
    this.layers.replaceChildren(...info.rows.map((row) => this.layerRow(row)));
    this.showSettings();
    this.loadThumbnails();
  }

  layerRow(row) {
    const item = document.createElement("div");
    item.className = "ds-source-list__item app__layer";
    item.setAttribute("role", "option");
    item.dataset.id = row.id;
    item.tabIndex = row.id === this.selected ? 0 : -1;
    item.setAttribute("aria-selected", String(row.id === this.selected));
    if (row.id === this.selected) item.setAttribute("aria-current", "true");
    item.style.setProperty("--depth", row.depth);
    item.classList.toggle("is-hidden", !row.visible);
    const kind = row.kind === "group" ? "folder" : ({ text: "text", vector: "vector", adjustment: "adjustment", smart: "smart" })[row.type];
    const visibility = row.visible ? t("Layers.Hide") : t("Layers.Show");
    item.innerHTML = `
      <button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__eye" data-toggle title="${escapeHTML(visibility)}" aria-label="${escapeHTML(visibility)}" aria-pressed="${row.visible}">${row.visible ? ICONS.eye : ICONS.eyeOff}</button>
      ${row.kind === "group"
        ? `<button class="ds-button ds-button--ghost ds-button--icon ds-button--xs app__disclosure${row.expanded ? " is-open" : ""}" data-expand aria-expanded="${row.expanded}" aria-label="${escapeHTML(row.name)}">${ICONS.chevron}</button>`
        : `<canvas class="app__thumbnail" width="48" height="48" aria-hidden="true"></canvas>`}
      <span class="app__layer-name">${escapeHTML(row.name)}</span>
      ${kind ? `<span class="app__layer-kind">${ICONS[kind]}</span>` : ""}`;
    const cached = this.thumbnails.get(row.id);
    if (cached) item.querySelector(".app__thumbnail")?.getContext("2d").putImageData(cached, 0, 0);
    return item;
  }

  async loadThumbnails() {
    const doc = this.doc;
    for (const row of this.info.rows) {
      if (row.kind !== "layer" || this.thumbnails.has(row.id)) continue;
      try {
        const { response, payload } = await this.engine.call("thumbnail", { doc, layer: row.id, size: 48 });
        if (doc !== this.doc) return;
        const image = new ImageData(48, 48);
        // Centred in the square.
        const ox = Math.floor((48 - response.width) / 2), oy = Math.floor((48 - response.height) / 2);
        for (let y = 0; y < response.height; y++) {
          image.data.set(payload.subarray(y * response.width * 4, (y + 1) * response.width * 4), ((y + oy) * 48 + ox) * 4);
        }
        this.thumbnails.set(row.id, image);
        this.layers.querySelector(`[data-id="${row.id}"] .app__thumbnail`)?.getContext("2d").putImageData(image, 0, 0);
      } catch {
        // A layer without a thumbnail still shows its name.
      }
    }
  }

  selectedRow() {
    return this.info?.rows.find((row) => row.id === this.selected) ?? null;
  }

  showSettings() {
    const row = this.selectedRow();
    this.settings.hidden = !row;
    if (!row) return;
    this.opacity.value = String(Math.round(row.opacity * 100));
    this.opacityValue.textContent = `${this.opacity.value}%`;
    const modes = [...(row.kind === "group" ? [{ id: "passThrough", label: t("Web.Layers.PassThrough") }] : []), ...this.info.blendModes];
    this.blend.replaceChildren(...modes.map((mode) => new Option(mode.label, mode.id, false, mode.id === row.blendMode)));
  }

  layerClicked(event) {
    const item = event.target.closest(".app__layer");
    if (!item) return;
    const row = this.info.rows.find((r) => r.id === item.dataset.id);
    if (event.target.closest("[data-toggle]")) {
      this.update({ visible: !row.visible }, row.id);
      return;
    }
    if (event.target.closest("[data-expand]")) {
      this.update({ expanded: !row.expanded }, row.id, { render: false });
      return;
    }
    this.select(row.id);
  }

  layerKey(event) {
    const rows = this.info?.rows ?? [];
    const index = rows.findIndex((row) => row.id === this.selected);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = rows[Math.min(Math.max(index + (event.key === "ArrowDown" ? 1 : -1), 0), rows.length - 1)];
      if (next) this.select(next.id, { focus: true });
    } else if (event.key === " ") {
      event.preventDefault();
      const row = this.selectedRow();
      if (row) this.update({ visible: !row.visible }, row.id);
    }
  }

  select(id, { focus = false } = {}) {
    this.selected = id;
    for (const item of this.layers.children) {
      const chosen = item.dataset.id === id;
      item.setAttribute("aria-selected", String(chosen));
      item.tabIndex = chosen ? 0 : -1;
      if (chosen) item.setAttribute("aria-current", "true");
      else item.removeAttribute("aria-current");
      if (chosen && focus) item.focus();
    }
    this.showSettings();
  }

  async update(changes, id = this.selected, { render = true } = {}) {
    if (this.doc === null || !id) return;
    try {
      const { response } = await this.engine.call("update", { doc: this.doc, id, ...changes });
      this.info = { ...this.info, ...response };
      const focused = this.layers.contains(document.activeElement);
      this.showInfo();
      if (focused) this.layers.querySelector('[aria-selected="true"]')?.focus();
      if (render) await this.render();
    } catch (error) {
      this.alert(error.message);
    }
  }

  // ------------------------------------------------------------ Window

  keyDown(event) {
    const command = isMac ? event.metaKey : event.ctrlKey;
    if (!command || event.altKey) return;
    const key = event.key.toLowerCase();
    const actions = { o: "open", n: "new", w: "close", "=": "zoomIn", "+": "zoomIn", "-": "zoomOut", 0: "fit", 1: "actual" };
    const action = actions[key];
    if (!action) return;
    if (["close", "zoomIn", "zoomOut", "fit", "actual"].includes(action) && this.doc === null) return;
    event.preventDefault();
    this.perform(action);
  }

  watchDrops() {
    const content = this.root;
    content.addEventListener("dragover", (event) => {
      if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
      this.root.classList.add("is-dropping");
    });
    content.addEventListener("dragleave", (event) => {
      if (!event.relatedTarget || !this.root.contains(event.relatedTarget)) this.root.classList.remove("is-dropping");
    });
    content.addEventListener("drop", async (event) => {
      event.preventDefault();
      this.root.classList.remove("is-dropping");
      const dropped = await droppedDocument(event.dataTransfer);
      if (!dropped) return;
      if (dropped.file) await this.openFile(dropped.file, { handle: dropped.handle });
      else await this.openPackageBytes(dropped.name, dropped.bytes);
    });
  }

  /** Files opened with the installed app from the system (manifest file_handlers). */
  watchLaunches() {
    if (!("launchQueue" in window)) return;
    window.launchQueue.setConsumer(async (params) => {
      const handle = params.files?.[0];
      if (handle) await this.openFile(await handle.getFile(), { handle });
    });
  }

  setBusy(message) {
    this.busy.hidden = !message;
    this.busy.querySelector(".ds-caption").textContent = message ?? "";
  }

  sheet(html) {
    const backdrop = document.createElement("div");
    backdrop.className = "ds-sheet-backdrop";
    backdrop.innerHTML = html;
    this.root.append(backdrop);
    backdrop.querySelector("[data-cancel]")?.addEventListener("click", () => dismissSheet(backdrop));
    backdrop.addEventListener("keydown", (event) => {
      if (event.key === "Escape") dismissSheet(backdrop);
    });
    return backdrop;
  }

  alert(message) {
    const backdrop = this.sheet(`
      <div class="ds-sheet ds-alert" role="alertdialog" aria-labelledby="alert-message">
        <div class="ds-sheet__body"><p class="ds-sheet__message" id="alert-message">${escapeHTML(message)}</p></div>
        <div class="ds-sheet__buttons"><button class="ds-button ds-button--primary" type="button" data-cancel>${escapeHTML(t("Web.Common.OK"))}</button></div>
      </div>`);
    backdrop.querySelector("[data-cancel]").focus();
  }

  about() {
    const version = globalThis.EASEL_APP_VERSION ?? "";
    this.alert(`Easel ${version}`.trim());
  }

  // ------------------------------------------------------------ Updates

  offerUpdate(download) {
    this.updateButton.classList.add("is-offered");
    this.updateButton.onclick = () => this.showUpdate(download);
  }

  showUpdate(download) {
    const backdrop = this.sheet(`
      <div class="ds-sheet" role="dialog" aria-labelledby="update-title" aria-describedby="update-message">
        <div class="ds-sheet__body">
          <h2 class="ds-sheet__title" id="update-title">${escapeHTML(t("Web.Update.Title"))}</h2>
          <p class="ds-sheet__message" id="update-message"></p>
          <div class="ds-progress" role="progressbar" aria-labelledby="update-title" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><div class="ds-progress__bar"></div></div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Common.Cancel"))}</button>
          <button class="ds-button ds-button--primary" type="button" data-retry hidden>${escapeHTML(t("Web.Update.TryAgain"))}</button>
        </div>
      </div>`);
    const message = backdrop.querySelector("#update-message");
    const progress = backdrop.querySelector(".ds-progress");
    const retry = backdrop.querySelector("[data-retry]");
    let open = true;
    backdrop.querySelector("[data-cancel]").addEventListener("click", () => {
      open = false;
    });
    const attempt = async () => {
      message.textContent = t("Web.Update.Downloading");
      retry.hidden = true;
      progress.hidden = false;
      try {
        await download((fraction) => {
          if (!open) return;
          const percent = Math.round(Math.min(Math.max(fraction, 0), 1) * 100);
          progress.style.setProperty("--ds-progress", `${percent}%`);
          progress.setAttribute("aria-valuenow", String(percent));
        });
        if (open) location.reload();
      } catch {
        if (!open) return;
        message.textContent = t("Web.Update.Failed");
        progress.hidden = true;
        retry.hidden = false;
      }
    };
    retry.addEventListener("click", attempt);
    attempt();
  }
}
