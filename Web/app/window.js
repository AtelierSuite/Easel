// Easel's window: the menu bar and toolbar, the canvas, the Layers inspector
// and the status bar, over one document at a time.

import { attachMenuBar, attachToolbarOverflow, openMenu } from "../design/menus.js";
import { dismissSheet } from "../design/sheets.js";
import { t, language } from "./i18n.js";
import { chooseFile, choosePackage, droppedDocument, bytesForEngine, picturesInside, readHandle, saveFile } from "./files.js";
import * as storage from "./storage.js";
import { Tools } from "./tools.js";
import { GPUCanvas } from "./canvas.js";
import { LayersInspector } from "./inspector.js";

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
  undo: icon('<path d="M5.5 3L2.5 6l3 3M2.5 6h7a4 4 0 0 1 0 8h-3" fill="none" stroke="currentColor"/>'),
  redo: icon('<path d="M10.5 3l3 3-3 3M13.5 6h-7a4 4 0 0 0 0 8h3" fill="none" stroke="currentColor"/>'),
  layers: icon('<path d="M8 2l6.5 3.5L8 9 1.5 5.5z" fill="none" stroke="currentColor"/><path d="M1.5 8.5L8 12l6.5-3.5M1.5 11.5L8 15l6.5-3.5" fill="none" stroke="currentColor"/>'),
  rotate: icon('<path d="M13 8a5 5 0 1 1-1.5-3.6M13 2v3h-3" fill="none" stroke="currentColor"/>'),
  plus: icon('<path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.5"/>'),
  duplicate: icon('<rect x="5.5" y="5.5" width="8" height="8" fill="none" stroke="currentColor"/><path d="M3.5 10.5h-1v-8h8v1" fill="none" stroke="currentColor"/>'),
  mergeDown: icon('<path d="M8 1.5v6M5.5 5L8 7.5 10.5 5" fill="none" stroke="currentColor"/><path d="M8 9l6.5 2.5L8 14l-6.5-2.5z" fill="currentColor"/>'),
  trash: icon('<path d="M2.5 4h11M6 4V2.5h4V4M4 4l.7 9.5h6.6L12 4" fill="none" stroke="currentColor"/>'),
  more: icon('<circle cx="3.5" cy="8" r="1.2" fill="currentColor"/><circle cx="8" cy="8" r="1.2" fill="currentColor"/><circle cx="12.5" cy="8" r="1.2" fill="currentColor"/>'),
  lock: icon('<rect x="3.5" y="7" width="9" height="7" rx="1" fill="currentColor"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" fill="none" stroke="currentColor"/>'),
  clipped: icon('<path d="M4 2.5v6.5h7M8.5 6.5L11 9l-2.5 2.5" fill="none" stroke="currentColor"/>'),
  smart: icon('<rect x="2.5" y="2.5" width="11" height="11" fill="none" stroke="currentColor"/><path d="M5 11l2.5-3 2 2 1.5-2" fill="none" stroke="currentColor"/>'),
};

const ZOOMS = [0.05, 0.0833, 0.125, 0.1667, 0.25, 0.3333, 0.5, 0.6667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32];
const DISPLAY_LIMIT = 4096;
const RECENT_LIMIT = 12;
const SOURCE_CODE_URL = "https://github.com/AtelierSuite/Easel";

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
    this.rotation = 0;
    this.renderToken = 0;
    this.thumbnails = new Map();
    this.build();
  }

  // ------------------------------------------------------------ Building

  build() {
    const viewButtons = `
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="zoomOut" title="${escapeHTML(t("Menu.ZoomOut"))}" aria-label="${escapeHTML(t("Menu.ZoomOut"))}" disabled>${ICONS.zoomOut}</button>
        <button class="ds-button ds-button--ghost app__zoom ds-numeric" data-action="actual" title="${escapeHTML(t("Canvas.ActualSize"))}" disabled>100%</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="zoomIn" title="${escapeHTML(t("Menu.ZoomIn"))}" aria-label="${escapeHTML(t("Menu.ZoomIn"))}" disabled>${ICONS.zoomIn}</button>
        <button class="ds-button ds-button--ghost app__rotation ds-numeric" data-action="resetRotation" title="${escapeHTML(t("Canvas.ResetRotation"))}" aria-label="${escapeHTML(t("Canvas.ResetRotation"))}" hidden>${ICONS.rotate}<span class="app__rotation-value"></span></button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="fit" title="${escapeHTML(t("Canvas.FitToScreen"))}" aria-label="${escapeHTML(t("Canvas.FitToScreen"))}" disabled>${ICONS.fit}</button>
        <div class="ds-toolbar__separator"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="export" title="${escapeHTML(t("Menu.Export"))}" aria-label="${escapeHTML(t("Menu.Export"))}" disabled>${ICONS.share}</button>`;
    this.root.innerHTML = `
      <div class="ds-menu-bar"></div>
      <div class="ds-toolbar app__toolbar">
        <div class="ds-toolbar__title" data-overflow="never"><span class="app__title">Easel</span><span class="ds-toolbar__subtitle app__subtitle"></span></div>
        <div class="ds-toolbar__spacer"></div>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="undo" title="${escapeHTML(t("Toolbar.Undo"))}" aria-label="${escapeHTML(t("Toolbar.Undo"))}" disabled>${ICONS.undo}</button>
        <button class="ds-button ds-button--ghost ds-button--icon" data-action="redo" title="${escapeHTML(t("Toolbar.Redo"))}" aria-label="${escapeHTML(t("Toolbar.Redo"))}" disabled>${ICONS.redo}</button>
        <div class="ds-toolbar__separator"></div>${viewButtons}
        <button class="ds-button ds-button--primary ds-button--xs app__update" data-overflow="never">${escapeHTML(t("Web.Update.Button"))}</button>
      </div>
      <nav class="app__tools" aria-label="${escapeHTML(t("Web.Tools.Title"))}" hidden></nav>
      <div class="ds-window__accessory app__options" hidden>
        <div class="app__options-tools"></div>
        <button class="ds-button ds-button--ghost ds-button--icon app__layers-toggle" data-action="layers" title="${escapeHTML(t("Web.Layers.Title"))}" aria-label="${escapeHTML(t("Web.Layers.Title"))}" aria-pressed="false">${ICONS.layers}</button>
      </div>
      <div class="ds-window__content app__content">
        <div class="app__start"></div>
        <div class="app__viewport" hidden><div class="app__stage"><canvas class="app__canvas"></canvas><svg class="app__overlay" aria-hidden="true"><g class="app__draft"></g><g class="app__ants"></g></svg></div></div>
        <div class="app__busy" hidden><div class="ds-spinner"></div><span class="ds-caption"></span></div>
      </div>
      <aside class="ds-inspector app__inspector" aria-label="${escapeHTML(t("Web.Layers.Title"))}" hidden></aside>
      <div class="ds-status-bar app__status" hidden>
        <span class="app__status-size ds-numeric"></span><span class="app__status-layers ds-numeric"></span>
      </div>`;
    const $ = (selector) => this.root.querySelector(selector);
    this.toolbar = $(".app__toolbar");
    this.title = $(".app__title");
    this.subtitle = $(".app__subtitle");
    this.start = $(".app__start");
    this.viewport = $(".app__viewport");
    this.stage = $(".app__stage");
    this.canvas = $(".app__canvas");
    this.overlay = $(".app__overlay");
    this.draftLayer = $(".app__draft");
    this.ants = $(".app__ants");
    this.busy = $(".app__busy");
    this.inspector = $(".app__inspector");
    this.status = $(".app__status");
    this.zoomLabels = [...this.root.querySelectorAll(".app__zoom")];
    this.rotationButton = $(".app__rotation");
    this.rotationLabel = $(".app__rotation-value");
    this.toolPicker = $(".app__tools");
    this.optionsBar = $(".app__options");
    this.layersToggle = $(".app__layers-toggle");
    this.updateButton = $(".app__update");

    this.menuBar = attachMenuBar($(".ds-menu-bar"), this.menus(), { label: "Easel" });
    attachToolbarOverflow(this.toolbar);
    this.pendingEdits = 0;
    try {
      this.canvasView = new GPUCanvas(this.canvas);
      this.canvasView.onRestore = () => this.render();
      this.gpu = true;
    } catch {
      // Without WebGL 2 the engine draws the whole picture, and strokes show once painted.
      this.canvasView = { beginStroke() {}, updateStroke() {}, endStroke() {}, cancelStroke() {} };
      this.gpu = false;
    }
    this.tools = new Tools(this);

    this.root.addEventListener("click", (event) => {
      const button = event.target.closest("[data-action]");
      if (button && !button.disabled) this.perform(button.dataset.action);
    });
    this.panel = new LayersInspector(this, this.inspector);
    document.addEventListener("paste", (event) => this.pasted(event));
    this.viewport.addEventListener("wheel", (event) => this.wheel(event), { passive: false });
    for (const type of ["gesturestart", "gesturechange", "gestureend"]) {
      this.viewport.addEventListener(type, (event) => this.trackpadGesture(event), { passive: false });
    }
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
        label: t("Menu.Edit"),
        get items() {
          return [
            { label: t("Toolbar.Undo"), shortcut: shortcut("Z"), disabled: !self.info?.canUndo, action: () => self.perform("undo") },
            { label: t("Toolbar.Redo"), shortcut: isMac ? "⇧⌘Z" : "Ctrl+Y", disabled: !self.info?.canRedo, action: () => self.perform("redo") },
          ];
        },
      },
      {
        label: t("Menu.Select"),
        get items() {
          const selected = Boolean(self.info?.selection);
          return [
            { label: t("Select.All"), shortcut: shortcut("A"), disabled: !has(), action: () => self.selectArea({ shape: "all" }) },
            { label: t("Select.Deselect"), shortcut: shortcut("D"), disabled: !selected, action: () => self.selectArea({ shape: "none" }) },
            { label: t("Select.Invert"), shortcut: isMac ? "⇧⌘I" : "Ctrl+Shift+I", disabled: !selected, action: () => self.selectArea({ shape: "invert" }) },
            { separator: true },
            { label: t("Select.Clear"), shortcut: isMac ? "⌫" : "Del", disabled: !selected, action: () => self.edit("clear", {}) },
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
            { label: t("Canvas.ResetRotation"), disabled: !has() || !self.rotation, action: () => self.perform("resetRotation") },
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
      case "fit": return this.fitView();
      case "resetRotation": return this.setRotation(0);
      case "export": return this.showExportMenu();
      case "layers": return this.toggleLayers();
      case "undo":
      case "redo": return this.edit(action, {}, { all: true });
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
    this.toolPicker.hidden = !shown;
    this.optionsBar.hidden = !shown;
    for (const button of this.root.querySelectorAll(".ds-toolbar [data-action]")) button.disabled = !shown;
    this.showUndo();
    this.tools.reset();
    if (!shown) this.toggleLayers(false);
    else this.tools.reveal();
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
    await this.load(() => this.openInEngine({ name, package: true }, bytes.slice()), name, { bytes: record ? null : bytes, isPackage: true, record });
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
      return this.openInEngine({ name: file.name }, bytes);
    }, file.name, { handle, bytes: copy, record });
  }

  /** Opens a document in the engine, first handing it the pictures inside that only the browser decodes. */
  async openInEngine(params, bytes) {
    for (const picture of await picturesInside(bytes)) await this.engine.call("picture", { key: picture.key }, picture.bytes);
    return this.engine.call("open", params, bytes);
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
      this.editingMask = false;
      this.title.textContent = this.name;
      document.title = `${this.name} – Easel`;
      this.showDocument(true);
      this.showInfo();
      this.zoom = this.fitZoom();
      this.rotation = 0;
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
    const buttons = [...this.root.querySelectorAll('[data-action="export"]')];
    openMenu(this.exportItems(), buttons.find((button) => button.offsetParent) ?? buttons[0]);
  }

  // Phones only: the Layers inspector opens under the canvas from the bottom bar.
  toggleLayers(open = !this.root.classList.contains("is-showing-layers")) {
    this.root.classList.toggle("is-showing-layers", open);
    this.layersToggle.setAttribute("aria-pressed", String(open));
    if (this.doc) this.layout();
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
    this.setView({ zoom }, anchor);
  }

  /** Turns the view `rotation` radians clockwise, keeping the picture under `anchor` (or the middle) still. */
  setRotation(rotation, anchor = null) {
    this.setView({ rotation }, anchor);
  }

  setView({ zoom = this.zoom, rotation = this.rotation }, anchor = null) {
    if (!this.info) return;
    const viewport = this.viewport;
    const viewRect = viewport.getBoundingClientRect();
    const point = anchor ?? { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 };
    const before = this.pictureAt(point.x + viewRect.left, point.y + viewRect.top);
    this.zoom = Math.min(32, Math.max(0.02, zoom));
    let turn = Math.atan2(Math.sin(rotation), Math.cos(rotation));
    if (Math.abs(turn) < 1e-4) turn = 0;
    this.rotation = turn;
    this.layout();
    const after = this.screenAt(before);
    viewport.scrollLeft += after.x - viewRect.left - point.x;
    viewport.scrollTop += after.y - viewRect.top - point.y;
  }

  /** Settles a turn that ended near upright, or on its side, square. */
  settleRotation() {
    const quarter = Math.PI / 2;
    const nearest = Math.round(this.rotation / quarter) * quarter;
    if (this.rotation !== nearest && Math.abs(this.rotation - nearest) < (8 * Math.PI) / 180) this.setRotation(nearest);
  }

  fitView() {
    this.rotation = 0;
    this.setZoom(this.fitZoom());
  }

  /** Where a point in the picture is on the screen. */
  screenAt(point) {
    const rect = this.canvas.getBoundingClientRect();
    const dx = (point.x - this.info.width / 2) * this.zoom, dy = (point.y - this.info.height / 2) * this.zoom;
    const cos = Math.cos(this.rotation), sin = Math.sin(this.rotation);
    return { x: rect.left + rect.width / 2 + dx * cos - dy * sin, y: rect.top + rect.height / 2 + dx * sin + dy * cos };
  }

  layout() {
    const { width, height } = this.info;
    const w = width * this.zoom, h = height * this.zoom;
    const cos = Math.abs(Math.cos(this.rotation)), sin = Math.abs(Math.sin(this.rotation));
    // The turned picture's bounds, with room to scroll its edges to the middle when it's larger than the window.
    const bw = w * cos + h * sin, bh = w * sin + h * cos;
    const padX = Math.max(32, (this.viewport.clientWidth - bw) / 2);
    const padY = Math.max(32, (this.viewport.clientHeight - bh) / 2);
    Object.assign(this.stage.style, { width: `${bw + padX * 2}px`, height: `${bh + padY * 2}px` });
    const place = { left: `${padX + (bw - w) / 2}px`, top: `${padY + (bh - h) / 2}px`, width: `${w}px`, height: `${h}px`, transform: this.rotation ? `rotate(${this.rotation}rad)` : "" };
    Object.assign(this.canvas.style, place);
    Object.assign(this.overlay.style, place);
    this.overlay.setAttribute("viewBox", `0 0 ${width} ${height}`);
    this.canvas.classList.toggle("is-pixelated", this.zoom > 2);
    for (const label of this.zoomLabels) label.textContent = t("Web.Zoom %lld", Math.round(this.zoom * 100));
    const degrees = Math.round((this.rotation * 180) / Math.PI);
    this.rotationButton.hidden = degrees === 0 && this.rotation === 0;
    this.rotationLabel.textContent = `${degrees}°`;
  }

  // Safari's pinch and turn on a trackpad. Touches are handled as pointers instead.
  trackpadGesture(event) {
    event.preventDefault();
    if (!this.info || this.tools.pointers.size) return;
    if (event.type === "gesturestart") {
      this.trackpad = { zoom: this.zoom, rotation: this.rotation, turning: false, offset: 0 };
      return;
    }
    const gesture = this.trackpad;
    if (!gesture) return;
    if (event.type === "gestureend") {
      if (gesture.turning) this.settleRotation();
      this.trackpad = null;
      return;
    }
    const twist = (event.rotation * Math.PI) / 180;
    if (!gesture.turning && Math.abs(twist) >= Math.PI / 18) {
      gesture.turning = true;
      gesture.offset = twist;
    }
    const viewRect = this.viewport.getBoundingClientRect();
    this.setView(
      { zoom: gesture.zoom * event.scale, rotation: gesture.turning ? gesture.rotation + twist - gesture.offset : this.rotation },
      { x: event.clientX - viewRect.left, y: event.clientY - viewRect.top },
    );
  }

  wheel(event) {
    if (!event.ctrlKey && !event.metaKey) return;
    event.preventDefault();
    const viewRect = this.viewport.getBoundingClientRect();
    this.setZoom(this.zoom * Math.exp(-event.deltaY * 0.01), { x: event.clientX - viewRect.left, y: event.clientY - viewRect.top });
  }

  /** Brings the canvas up to date with the engine: after a stroke (`onlyActive`), just the layer painted. */
  async render({ onlyActive = false } = {}) {
    if (this.doc === null) return;
    if (this.gpu) return this.refreshParts(onlyActive);
    const token = ++this.renderToken;
    const maxSize = Math.min(Math.max(this.info.width, this.info.height), DISPLAY_LIMIT);
    const { response, payload } = await this.engine.call("render", { doc: this.doc, maxSize });
    if (token !== this.renderToken) return;
    this.canvas.width = response.width;
    this.canvas.height = response.height;
    const context = this.canvas.getContext("2d");
    context.putImageData(new ImageData(new Uint8ClampedArray(payload.buffer, payload.byteOffset, payload.byteLength), response.width, response.height), 0, 0);
  }

  async refreshParts(onlyActive) {
    const token = ++this.renderToken;
    const view = this.canvasView;
    const request = { doc: this.doc, layer: this.selected, maxSize: Math.min(DISPLAY_LIMIT, view.maxSize) };
    let answer = await this.engine.call("canvas", onlyActive && view.key ? { ...request, only: "active" } : request);
    if (onlyActive && (!view.fits(answer.response.key) || !answer.response.rendered.length)) {
      answer = await this.engine.call("canvas", request);
    }
    if (token !== this.renderToken) return;
    view.scale = this.info.width / answer.response.width;
    view.setParts(answer.response, answer.payload);
    view.clearOverlay();
  }

  /** A point on the screen as a point in the picture's own pixels. */
  pictureAt(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();
    const dx = clientX - rect.left - rect.width / 2, dy = clientY - rect.top - rect.height / 2;
    const cos = Math.cos(this.rotation), sin = Math.sin(this.rotation);
    return {
      x: (dx * cos + dy * sin) / this.zoom + this.info.width / 2,
      y: (-dx * sin + dy * cos) / this.zoom + this.info.height / 2,
    };
  }

  /** The colour shown at a point in the picture, straight alpha, 0–255. */
  colorAt(point) {
    const scale = this.canvas.width / this.info.width;
    const x = Math.floor(point.x * scale), y = Math.floor(point.y * scale);
    if (x < 0 || y < 0 || x >= this.canvas.width || y >= this.canvas.height) return null;
    if (this.gpu) return this.canvasView.colorAt(x, y);
    return [...this.canvas.getContext("2d").getImageData(x, y, 1, 1).data];
  }

  // ------------------------------------------------------------ Layers

  showInfo() {
    const info = this.info;
    this.showSelection();
    const number = new Intl.NumberFormat(language);
    this.root.querySelector(".app__status-size").textContent = t("Web.Status.Size %lld %lld", number.format(Math.round(info.width)), number.format(Math.round(info.height)));
    this.root.querySelector(".app__status-layers").textContent = t("Web.Status.Layers %lld", info.rows.filter((row) => row.kind === "layer").length);
    this.subtitle.textContent = this.root.querySelector(".app__status-size").textContent;
    this.panel.render();
  }

  selectedRow() {
    return this.info?.rows.find((row) => row.id === this.selected) ?? null;
  }

  /** Whether painting goes into the picked layer's mask: asked for, or an adjustment layer's, which is all it has. */
  paintsMask() {
    const row = this.selectedRow();
    return Boolean(row?.masked && (this.editingMask || row.type === "adjustment"));
  }

  select(id, { focus = false, mask = false } = {}) {
    const changed = id !== this.selected;
    this.selected = id;
    this.editingMask = mask;
    this.panel.render();
    if (focus) this.panel.list.querySelector('[aria-selected="true"]')?.focus();
    this.tools.changed();
    // The layer painted on is the one the canvas keeps apart.
    if (this.gpu && changed) this.render();
  }


  showUndo() {
    this.toolbar.querySelector('[data-action="undo"]').disabled = !this.info?.canUndo || this.doc === null;
    this.toolbar.querySelector('[data-action="redo"]').disabled = !this.info?.canRedo || this.doc === null;
  }

  /** A change the engine makes to the selected layer's pixels, or Undo or Redo (`all`, as any layer may change). */
  async edit(op, params, { all = false, select = true, payload } = {}) {
    if (this.doc === null) return false;
    this.pendingEdits++;
    try {
      const mask = ["stroke", "fill", "gradient"].includes(op) && this.editingMask ? { mask: true } : {};
      const { response } = await this.engine.call(op, { doc: this.doc, layer: this.selected, ...mask, ...params }, payload);
      const resized = response.width !== this.info.width || response.height !== this.info.height;
      this.info = { ...this.info, ...response };
      if (response.added && select && response.added !== this.selected) {
        this.selected = response.added;
        this.editingMask = false;
      }
      if (resized) {
        this.zoom = this.fitZoom();
        this.layout();
      }
      if (all) this.thumbnails.clear();
      else this.thumbnails.delete(this.selected);
      if (!this.info.rows.some((row) => row.id === this.selected)) this.selected = this.info.rows.find((row) => row.kind === "layer")?.id ?? null;
      if (!this.selectedRow()?.masked) this.editingMask = false;
      this.showInfo();
      this.showUndo();
      this.tools.changed();
      // Strokes drawn meanwhile are still showing; the canvas catches up once the last is painted.
      if (--this.pendingEdits === 0) await this.render({ onlyActive: !all });
      return true;
    } catch (error) {
      if (--this.pendingEdits === 0) await this.render();
      this.alert(error.message);
      return false;
    }
  }

  /** Changes the selection: a shape drawn, a colour picked, all, none or the rest. Not a step Undo takes back. */
  async selectArea(params) {
    if (this.doc === null) return;
    try {
      const { response } = await this.engine.call("select", { doc: this.doc, ...params });
      this.info = { ...this.info, ...response };
      this.showSelection();
    } catch (error) {
      this.alert(error.message);
    }
  }

  showSelection() {
    const path = this.info?.selection;
    this.ants.innerHTML = path
      ? `<path d="${path}" fill-rule="evenodd" class="app__ants-light"/><path d="${path}" fill-rule="evenodd" class="app__ants-dark"/>`
      : "";
  }

  /** What a tool is drawing, as SVG in the picture's pixels, shown over the canvas until it's done. */
  draft(markup = "") {
    this.draftLayer.innerHTML = markup;
  }

  /** Asks for a text layer's words; resolves to them, or null if cancelled. */
  askText(initial = "") {
    return new Promise((resolve) => {
      const backdrop = this.sheet(`
        <form class="ds-sheet" role="dialog" aria-labelledby="text-title">
          <div class="ds-sheet__body">
            <h2 class="ds-sheet__title" id="text-title">${escapeHTML(t("Options.EditText"))}</h2>
            <textarea class="ds-text-input app__text-input" rows="3" aria-labelledby="text-title"></textarea>
          </div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Common.Cancel"))}</button>
            <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Common.Done"))}</button>
          </div>
        </form>`);
      const form = backdrop.querySelector("form");
      const input = form.querySelector("textarea");
      input.value = initial;
      let answer = null;
      const observer = new MutationObserver(() => {
        if (backdrop.isConnected) return;
        observer.disconnect();
        resolve(answer);
      });
      observer.observe(this.root, { childList: true });
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        answer = input.value;
        dismissSheet(backdrop);
      });
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) form.requestSubmit();
      });
      input.select();
    });
  }

  /** Asks for a layer's or group's new name; resolves to it, or null if cancelled. */
  askName(initial = "") {
    return this.ask({ title: t("Layers.Rename.Title"), placeholder: t("Layers.Rename.Placeholder"), confirm: t("Layers.Rename.Confirm"), value: initial });
  }

  /** Asks for one line of text, or a number with `type: "number"`; resolves to it, or null if cancelled. */
  ask({ title, message = "", placeholder = "", confirm = t("Common.OK"), value = "", type = "text" }) {
    return new Promise((resolve) => {
      const backdrop = this.sheet(`
        <form class="ds-sheet" role="dialog" aria-labelledby="ask-title">
          <div class="ds-sheet__body">
            <h2 class="ds-sheet__title" id="ask-title">${escapeHTML(title)}</h2>
            ${message ? `<p class="ds-sheet__message">${escapeHTML(message)}</p>` : ""}
            <input class="ds-text-input${type === "number" ? " ds-numeric" : ""}" type="${type}" step="any" aria-labelledby="ask-title" placeholder="${escapeHTML(placeholder)}">
          </div>
          <div class="ds-sheet__buttons">
            <button class="ds-button" type="button" data-cancel>${escapeHTML(t("Common.Cancel"))}</button>
            <button class="ds-button ds-button--primary" type="submit">${escapeHTML(confirm)}</button>
          </div>
        </form>`);
      const form = backdrop.querySelector("form");
      const input = form.querySelector("input");
      input.value = value;
      let answer = null;
      const observer = new MutationObserver(() => {
        if (backdrop.isConnected) return;
        observer.disconnect();
        resolve(answer);
      });
      observer.observe(this.root, { childList: true });
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        answer = input.value;
        dismissSheet(backdrop);
      });
      input.select();
    });
  }

  /** A picture pasted with ⌘V becomes a layer of its own. */
  pasted(event) {
    if (this.doc === null || event.target.closest?.("input, textarea")) return;
    const file = [...(event.clipboardData?.files ?? [])].find((item) => item.type.startsWith("image/"));
    if (!file) return;
    event.preventDefault();
    this.panel.addPicture(file, file.name);
  }

  async update(changes, id = this.selected, { render = true } = {}) {
    if (this.doc === null || !id) return;
    try {
      const { response } = await this.engine.call("update", { doc: this.doc, id, ...changes });
      this.info = { ...this.info, ...response };
      this.showUndo();
      this.showInfo();
      this.tools.changed();
      if (render) await this.render();
    } catch (error) {
      this.alert(error.message);
    }
  }

  // ------------------------------------------------------------ Window

  keyDown(event) {
    const command = isMac ? event.metaKey : event.ctrlKey;
    const typing = event.target.closest?.("input, select, textarea, .ds-sheet");
    if (!command && this.doc !== null && !typing && this.tools.key(event)) return;
    if (!command && (event.key === "Backspace" || event.key === "Delete") && this.info?.selection && !typing) {
      event.preventDefault();
      this.edit("clear", {});
      return;
    }
    if (!command || event.altKey) return;
    const key = event.key.toLowerCase();
    if (this.doc !== null && !typing && (key === "a" || key === "d" || (key === "i" && event.shiftKey))) {
      event.preventDefault();
      this.selectArea({ shape: key === "a" && !event.shiftKey ? "all" : key === "i" ? "invert" : "none" });
      return;
    }
    if ((key === "z" || key === "y") && this.doc !== null && !event.target.closest?.("input, select, textarea")) {
      event.preventDefault();
      this.perform(key === "y" || event.shiftKey ? "redo" : "undo");
      return;
    }
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
        <div class="ds-sheet__body">
          <svg class="ds-alert__icon" viewBox="0 0 32 32" aria-hidden="true"><path d="M16 3 30 28H2z"/><path d="M16 11v9M16 23v2" stroke="var(--ds-layer-01)" stroke-width="2.5" stroke-linecap="round"/></svg>
          <div><p class="ds-sheet__message" id="alert-message">${escapeHTML(message)}</p></div>
        </div>
        <div class="ds-sheet__buttons"><button class="ds-button ds-button--primary" type="button" data-cancel>${escapeHTML(t("Web.Common.OK"))}</button></div>
      </div>`);
    backdrop.querySelector("[data-cancel]").focus();
  }

  about() {
    const backdrop = this.sheet(`
      <div class="ds-sheet ds-alert app__about" role="alertdialog" aria-labelledby="about-title" aria-describedby="about-message">
        <div class="ds-sheet__body">
          <img class="app__about-icon" src="app/icons/icon.svg" width="48" height="48" alt="" draggable="false">
          <div>
            <h2 class="ds-sheet__title" id="about-title">Easel</h2>
            <p class="ds-caption app__about-version"></p>
            <p class="ds-sheet__message" id="about-message"></p>
            <p class="ds-sheet__message app__about-suite"><a href="https://atelier.ktgk.app" target="_blank" rel="noopener"></a></p>
          </div>
        </div>
        <div class="ds-sheet__buttons">
          <button class="ds-button" type="button" data-source>${escapeHTML(t("Toolbar.SourceCode"))}</button>
          <button class="ds-button ds-button--primary" type="button" data-cancel>${escapeHTML(t("Web.Common.Close"))}</button>
        </div>
      </div>`);
    backdrop.querySelector("#about-message").textContent = t("Web.About.Message");
    backdrop.querySelector(".app__about-version").textContent = t("Web.About.Version", globalThis.EASEL_APP_VERSION ?? "");
    backdrop.querySelector(".app__about-suite a").textContent = t("Web.About.Suite");
    backdrop.querySelector("[data-source]").addEventListener("click", () => window.open(SOURCE_CODE_URL, "_blank", "noopener"));
    backdrop.querySelector("[data-cancel]").focus();
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
