// The page's side of the engine worker: sends requests and hands back the
// engine's answers, with any bytes it returned (pixels, or a saved file).
//
//   const engine = new EngineClient();
//   const { response, payload } = await engine.call("render", { doc: 1 });
//   engine.addEventListener("progress", ...)  // while starting: { loaded, total } bytes downloaded

export class EngineError extends Error {
  constructor(message, { fatal = false } = {}) {
    super(message);
    this.fatal = fatal;
  }
}

export class EngineClient extends EventTarget {
  /** @param {{ keepForOffline?: boolean }} [options] keepForOffline: leave the downloaded engine for the service worker's first install */
  constructor({ keepForOffline = false } = {}) {
    super();
    const url = new URL("../engine/worker.js", import.meta.url);
    url.searchParams.set("tz", Intl.DateTimeFormat().resolvedOptions().timeZone ?? "UTC");
    if (keepForOffline) url.searchParams.set("keep", "1");
    this.worker = new Worker(url, { type: "module" });
    this.pending = new Map();
    this.nextId = 1;
    this.worker.addEventListener("message", (event) => this.receive(event.data));
    this.worker.addEventListener("error", (event) => {
      for (const { reject } of this.pending.values()) reject(new EngineError(event.message || "The engine could not start.", { fatal: true }));
      this.pending.clear();
      this.dispatchEvent(new CustomEvent("fatal", { detail: event.message }));
    });
  }

  receive({ id, response, payload, error, fatal, progress }) {
    if (progress) {
      this.dispatchEvent(new CustomEvent("progress", { detail: progress }));
      return;
    }
    const entry = this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id);
    if (error) {
      entry.reject(new EngineError(error, { fatal }));
      if (fatal) this.dispatchEvent(new CustomEvent("fatal", { detail: error }));
      return;
    }
    entry.resolve({ response, payload });
  }

  send(request, payload) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, request, payload }, payload ? [payload.buffer] : []);
    });
  }

  /** Runs one request; rejects with the engine's message when it fails. */
  async call(op, args = {}, payload) {
    const { response, payload: output } = await this.send({ op, ...args }, payload);
    if (!response.ok) throw new EngineError(response.error);
    return { response, payload: output };
  }
}
