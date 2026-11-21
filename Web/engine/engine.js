// Loads the Easel engine (easel-engine.wasm) and calls it. Runs anywhere
// WebAssembly does: in the app's worker, and in Node for the smoke tests.
//
//   const engine = await Engine.load(bytesOrResponse);
//   const { response, payload } = engine.call({ op: "new", width: 800, height: 600 });

import { WASIHost } from "./wasi.js";
import { TextHost } from "./text.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class Engine {
  /** @param {WebAssembly.Instance} instance @param {WASIHost} host */
  constructor(instance, host) {
    this.instance = instance;
    this.exports = instance.exports;
    this.host = host;
  }

  /**
   * @param {Response | BufferSource | Promise<Response>} source the module, as a fetch response or bytes
   * @param {{ stdout?: (line: string) => void, stderr?: (line: string) => void, env?: Record<string, string> }} [options]
   */
  static async load(source, options = {}) {
    const host = new WASIHost({ args: ["easel"], ...options });
    const text = new TextHost();
    let memory = null;
    const imports = { ...host.imports, easel: text.imports(() => memory) };
    const resolved = await source;
    const { instance } =
      typeof Response !== "undefined" && resolved instanceof Response
        ? await WebAssembly.instantiateStreaming(resolved, imports)
        : await WebAssembly.instantiate(resolved, imports);
    memory = instance.exports.memory;
    host.initialize(instance);
    return new Engine(instance, host);
  }

  copyIn(bytes) {
    const pointer = this.exports.easel_alloc(Math.max(bytes.length, 1));
    new Uint8Array(this.exports.memory.buffer, pointer, bytes.length).set(bytes);
    return pointer;
  }

  /**
   * Sends one request. `payload` is optional bytes, such as a file to open.
   * Returns the parsed JSON response and any bytes the engine handed back, such as pixels or a saved file.
   * @param {object} request
   * @param {Uint8Array} [payload]
   * @returns {{ response: any, payload: Uint8Array | null }}
   */
  call(request, payload) {
    const json = encoder.encode(JSON.stringify(request));
    const requestPointer = this.copyIn(json);
    const payloadPointer = payload ? this.copyIn(payload) : 0;
    try {
      this.exports.easel_call(requestPointer, json.length, payloadPointer, payload ? payload.length : 0);
    } finally {
      this.exports.easel_free(requestPointer);
      if (payloadPointer) this.exports.easel_free(payloadPointer);
      this.host.flush();
    }
    const memory = this.exports.memory.buffer;
    const responseBytes = new Uint8Array(memory, this.exports.easel_response_pointer(), this.exports.easel_response_length());
    const response = JSON.parse(decoder.decode(responseBytes));
    const payloadLength = this.exports.easel_payload_length();
    const output = payloadLength > 0
      ? new Uint8Array(memory, this.exports.easel_payload_pointer(), payloadLength).slice()
      : null;
    return { response, payload: output };
  }
}
