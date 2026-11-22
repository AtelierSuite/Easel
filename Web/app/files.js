// Getting files in and out: the File System Access API where the browser has
// it, a file input and downloads elsewhere. Pictures in formats the engine
// doesn't read itself (HEIC, WebP, TIFF, AVIF, BMP) are decoded by the
// browser and handed over as pixels. Package folders (.easel, .pxd) are
// zipped on the way in, since the engine takes one run of bytes.

const DOCUMENT_TYPES = {
  "image/vnd.adobe.photoshop": [".psd", ".psb"],
  "application/octet-stream": [".pxd", ".easel"],
  "image/png": [".png"],
  "image/jpeg": [".jpg", ".jpeg"],
  "image/gif": [".gif"],
  "image/heic": [".heic", ".heif"],
  "image/webp": [".webp"],
  "image/tiff": [".tif", ".tiff"],
  "image/avif": [".avif"],
  "image/bmp": [".bmp"],
};

const ENGINE_READS = new Set(["psd", "psb", "pxd", "easel", "zip", "png", "jpg", "jpeg", "gif"]);

const extension = (name) => (name.includes(".") ? name.slice(name.lastIndexOf(".") + 1).toLowerCase() : "");

/** A file input kept in the document: Safari only opens the first pick from one that is. */
let fallbackInput = null;

function pickWithInput({ directory = false } = {}) {
  return new Promise((resolve) => {
    fallbackInput?.remove();
    const input = document.createElement("input");
    input.type = "file";
    input.hidden = true;
    if (directory) input.webkitdirectory = true;
    else input.accept = [...Object.values(DOCUMENT_TYPES).flat(), "image/*"].join(",");
    input.addEventListener("change", () => resolve(directory ? [...input.files] : input.files[0] ?? null), { once: true });
    input.addEventListener("cancel", () => resolve(null), { once: true });
    document.body.append(input);
    fallbackInput = input;
    input.click();
  });
}

/** The file the person picks, with its handle where the browser gives one; or null. */
export async function chooseFile() {
  if ("showOpenFilePicker" in window) {
    try {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: "Images", accept: DOCUMENT_TYPES }],
        excludeAcceptAllOption: false,
        id: "easel-open",
      });
      return { file: await handle.getFile(), handle };
    } catch (error) {
      if (error.name === "AbortError") return null;
    }
  }
  const file = await pickWithInput();
  return file ? { file } : null;
}

/** The file behind a kept handle, asking for permission again if needed; null if refused. */
export async function readHandle(handle) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "read" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "read" })) !== "granted") return null;
  }
  return handle.getFile();
}

/** A package folder the person picks, zipped, with its name; or null. */
export async function choosePackage() {
  if ("showDirectoryPicker" in window) {
    try {
      const directory = await window.showDirectoryPicker({ id: "easel-package" });
      const entries = [];
      await readDirectory(directory, "", entries);
      return { name: directory.name, bytes: zip(entries) };
    } catch (error) {
      if (error.name === "AbortError") return null;
    }
  }
  const files = await pickWithInput({ directory: true });
  if (!files?.length) return null;
  const root = files[0].webkitRelativePath.split("/")[0];
  const entries = await Promise.all(files.map(async (file) => ({
    path: file.webkitRelativePath.slice(root.length + 1),
    bytes: new Uint8Array(await file.arrayBuffer()),
  })));
  return { name: root, bytes: zip(entries) };
}

async function readDirectory(directory, prefix, entries) {
  for await (const [name, handle] of directory.entries()) {
    if (handle.kind === "directory") await readDirectory(handle, `${prefix}${name}/`, entries);
    else entries.push({ path: `${prefix}${name}`, bytes: new Uint8Array(await (await handle.getFile()).arrayBuffer()) });
  }
}

/** Dropped items: a file, or a package folder zipped. */
export async function droppedDocument(dataTransfer) {
  // Everything is taken from the drop before the first wait, after which the browser empties it.
  const item = [...(dataTransfer.items ?? [])].find((i) => i.kind === "file");
  const entry = item?.webkitGetAsEntry?.();
  const file = dataTransfer.files?.[0];
  const handlePromise = entry?.isDirectory ? null : item?.getAsFileSystemHandle?.().catch(() => null);
  if (entry?.isDirectory) {
    const entries = [];
    await readChildren(entry, "", entries);
    return { name: entry.name, bytes: zip(entries), isPackage: true };
  }
  const handle = await handlePromise;
  return file ? { file, handle: handle?.kind === "file" ? handle : undefined } : null;
}

async function readEntry(entry, prefix, entries) {
  if (entry.isFile) {
    const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
    entries.push({ path: `${prefix}${entry.name}`, bytes: new Uint8Array(await file.arrayBuffer()) });
    return;
  }
  await readChildren(entry, `${prefix}${entry.name}/`, entries);
}

/** A folder's contents, with paths inside it. */
async function readChildren(directory, prefix, entries) {
  const reader = directory.createReader();
  for (;;) {
    const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
    if (!batch.length) return;
    for (const child of batch) await readEntry(child, prefix, entries);
  }
}

/**
 * The bytes to hand the engine for a file: as they are where it reads the
 * format itself, or the browser's decoding of a picture.
 */
export async function bytesForEngine(file) {
  const kind = extension(file.name);
  if (ENGINE_READS.has(kind) || (!file.type.startsWith("image/") && !["heic", "heif", "webp", "tif", "tiff", "avif", "bmp"].includes(kind))) {
    return new Uint8Array(await file.arrayBuffer());
  }
  return decodePicture(file);
}

/** The key the engine finds a picture by: its length and FNV-1a hash, as DecodedPictures works it out. */
export function pictureKey(bytes) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) hash = Math.imul(hash ^ bytes[i], 0x01000193) >>> 0;
  return `${bytes.length}-${hash.toString(16)}`;
}

/** Whether the engine needs the browser to decode a picture: HEIC, WebP, AVIF, TIFF or BMP. */
function needsBrowser(bytes) {
  const text = (from, to) => String.fromCharCode(...bytes.subarray(from, to));
  if (bytes.length < 12) return false;
  if (text(4, 8) === "ftyp") return true;
  if (text(0, 4) === "RIFF" && text(8, 12) === "WEBP") return true;
  if ((bytes[0] === 0x49 && bytes[1] === 0x49 && bytes[2] === 0x2a) || (bytes[0] === 0x4d && bytes[1] === 0x4d && bytes[3] === 0x2a)) return true;
  return text(0, 2) === "BM";
}

/**
 * The pictures inside a zipped document (a Pixelmator Pro file, or a package
 * zipped up) that only the browser can decode, decoded: { key, bytes } each.
 * Pictures it can't decode either are left out.
 */
export async function picturesInside(bytes) {
  if (bytes.length < 22 || bytes[0] !== 0x50 || bytes[1] !== 0x4b) return [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) {
    if (view.getUint32(i, true) === 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0) return [];
  let entry = view.getUint32(end + 16, true);
  const count = view.getUint16(end + 10, true);
  const found = [];
  for (let n = 0; n < count && entry + 46 <= bytes.length && view.getUint32(entry, true) === 0x02014b50; n++) {
    const method = view.getUint16(entry + 10, true);
    const size = view.getUint32(entry + 20, true);
    const nameLength = view.getUint16(entry + 28, true), extraLength = view.getUint16(entry + 30, true), commentLength = view.getUint16(entry + 32, true);
    const local = view.getUint32(entry + 42, true);
    entry += 46 + nameLength + extraLength + commentLength;
    if (local + 30 > bytes.length || view.getUint32(local, true) !== 0x04034b50) continue;
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    const stored = bytes.subarray(start, start + size);
    let data;
    if (method === 0) data = stored;
    else if (method === 8) data = new Uint8Array(await new Response(new Blob([stored]).stream().pipeThrough(new DecompressionStream("deflate-raw"))).arrayBuffer());
    else continue;
    if (!needsBrowser(data)) continue;
    const key = pictureKey(data);
    if (found.some((picture) => picture.key === key)) continue;
    try {
      found.push({ key, bytes: await decodePicture(new Blob([data])) });
    } catch {
      // The browser can't read it either: the engine leaves that layer out, as before.
    }
  }
  return found;
}

/** A picture decoded by the browser, behind the header the engine reads as raw pixels. */
export async function decodePicture(blob) {
  const bitmap = await createImageBitmap(blob, { premultiplyAlpha: "none", colorSpaceConversion: "default" });
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
  const context = canvas.getContext("2d");
  context.drawImage(bitmap, 0, 0);
  const pixels = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
  const bytes = new Uint8Array(17 + pixels.length);
  bytes.set(new TextEncoder().encode("EaselRGBA"));
  const view = new DataView(bytes.buffer);
  view.setUint32(9, bitmap.width, true);
  view.setUint32(13, bitmap.height, true);
  bytes.set(pixels, 17);
  bitmap.close();
  return bytes;
}

/** Saves bytes under a name, with the system's save panel where there is one. */
export async function saveFile(bytes, name, type) {
  const blob = new Blob([bytes], { type });
  if ("showSaveFilePicker" in window) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: name,
        id: "easel-export",
        types: [{ description: name, accept: { [type]: [`.${extension(name)}`] } }],
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      return true;
    } catch (error) {
      if (error.name === "AbortError") return false;
    }
  }
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 60_000);
  return true;
}

// ------------------------------------------------------------------ Zip

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/** A zip of the entries, stored without compression: it only travels to the engine. */
export function zip(entries) {
  const encoder = new TextEncoder();
  const parts = [];
  const central = [];
  let offset = 0;
  for (const { path, bytes } of entries) {
    if (path.split("/").some((part) => part === ".DS_Store" || part === "__MACOSX")) continue;
    const name = encoder.encode(path);
    const crc = crc32(bytes);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, bytes.length, true);
    local.setUint32(22, bytes.length, true);
    local.setUint16(26, name.length, true);
    parts.push(new Uint8Array(local.buffer), name, bytes);
    const record = new DataView(new ArrayBuffer(46));
    record.setUint32(0, 0x02014b50, true);
    record.setUint16(4, 20, true);
    record.setUint16(6, 20, true);
    record.setUint16(8, 0x0800, true);
    record.setUint32(16, crc, true);
    record.setUint32(20, bytes.length, true);
    record.setUint32(24, bytes.length, true);
    record.setUint16(28, name.length, true);
    record.setUint32(42, offset, true);
    central.push(new Uint8Array(record.buffer), name);
    offset += 30 + name.length + bytes.length;
  }
  const centralSize = central.reduce((sum, part) => sum + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, central.length / 2, true);
  end.setUint16(10, central.length / 2, true);
  end.setUint32(12, centralSize, true);
  end.setUint32(16, offset, true);
  const all = [...parts, ...central, new Uint8Array(end.buffer)];
  const out = new Uint8Array(all.reduce((sum, part) => sum + part.length, 0));
  let position = 0;
  for (const part of all) {
    out.set(part, position);
    position += part.length;
  }
  return out;
}
