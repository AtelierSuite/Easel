// HEIC photos for browsers that don't read them as pictures but can decode
// HEVC video (Chrome and Edge, where the device has a hardware decoder): the
// HEIF container is read here, and its tiles are decoded as video frames
// with WebCodecs and laid out on a canvas.

/** Whether the bytes are a HEIF picture. */
export function isHEIF(bytes) {
  if (bytes.length < 12) return false;
  const type = String.fromCharCode(...bytes.subarray(4, 8));
  const brand = String.fromCharCode(...bytes.subarray(8, 12));
  return type === "ftyp" && ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"].includes(brand);
}

/** The boxes in `bytes` from `start` to `end`: { type, start (of the body), end }. */
function boxes(view, start, end) {
  const found = [];
  let at = start;
  while (at + 8 <= end) {
    let size = view.getUint32(at);
    const type = String.fromCharCode(view.getUint8(at + 4), view.getUint8(at + 5), view.getUint8(at + 6), view.getUint8(at + 7));
    let header = 8;
    if (size === 1) {
      size = Number(view.getBigUint64(at + 8));
      header = 16;
    } else if (size === 0) {
      size = end - at;
    }
    if (size < header || at + size > end) break;
    found.push({ type, start: at + header, end: at + size });
    at += size;
  }
  return found;
}

/** A big-endian unsigned number `size` bytes long (0, 4 or 8). */
function uint(view, at, size) {
  if (size === 0) return 0;
  if (size === 2) return view.getUint16(at);
  if (size === 4) return view.getUint32(at);
  return Number(view.getBigUint64(at));
}

/** What the decoder needs from a HEIF file: its items, where their data lies, their properties and references. */
function readHEIF(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const meta = boxes(view, 0, bytes.length).find((box) => box.type === "meta");
  if (!meta) throw new Error("No meta box");
  const children = boxes(view, meta.start + 4, meta.end);
  const child = (type) => children.find((box) => box.type === type);
  const result = { primary: 0, types: new Map(), locations: new Map(), properties: [], associations: new Map(), references: [], idat: null };

  const pitm = child("pitm");
  if (pitm) result.primary = view.getUint8(pitm.start) === 0 ? view.getUint16(pitm.start + 4) : view.getUint32(pitm.start + 4);

  const iinf = child("iinf");
  if (iinf) {
    const version = view.getUint8(iinf.start);
    for (const infe of boxes(view, iinf.start + (version === 0 ? 6 : 8), iinf.end)) {
      if (infe.type !== "infe") continue;
      const v = view.getUint8(infe.start);
      if (v < 2) continue;
      const id = v === 2 ? view.getUint16(infe.start + 4) : view.getUint32(infe.start + 4);
      const typeAt = infe.start + (v === 2 ? 8 : 10);
      result.types.set(id, String.fromCharCode(...bytes.subarray(typeAt, typeAt + 4)));
    }
  }

  const iloc = child("iloc");
  if (iloc) {
    const version = view.getUint8(iloc.start);
    let at = iloc.start + 4;
    const sizes = view.getUint8(at), more = view.getUint8(at + 1);
    const offsetSize = sizes >> 4, lengthSize = sizes & 15, baseSize = more >> 4, indexSize = version > 0 ? more & 15 : 0;
    at += 2;
    const count = version < 2 ? view.getUint16(at) : view.getUint32(at);
    at += version < 2 ? 2 : 4;
    for (let i = 0; i < count; i++) {
      const id = version < 2 ? view.getUint16(at) : view.getUint32(at);
      at += version < 2 ? 2 : 4;
      let method = 0;
      if (version > 0) {
        method = view.getUint16(at) & 15;
        at += 2;
      }
      at += 2;
      const base = uint(view, at, baseSize);
      at += baseSize;
      const extentCount = view.getUint16(at);
      at += 2;
      const extents = [];
      for (let e = 0; e < extentCount; e++) {
        at += indexSize;
        const offset = uint(view, at, offsetSize);
        at += offsetSize;
        const length = uint(view, at, lengthSize);
        at += lengthSize;
        extents.push({ offset: base + offset, length });
      }
      result.locations.set(id, { method, extents });
    }
  }

  const idat = child("idat");
  if (idat) result.idat = bytes.subarray(idat.start, idat.end);

  const iref = child("iref");
  if (iref) {
    const wide = view.getUint8(iref.start) !== 0;
    for (const reference of boxes(view, iref.start + 4, iref.end)) {
      let at = reference.start;
      const from = wide ? view.getUint32(at) : view.getUint16(at);
      at += wide ? 4 : 2;
      const count = view.getUint16(at);
      at += 2;
      const to = [];
      for (let i = 0; i < count; i++) {
        to.push(wide ? view.getUint32(at) : view.getUint16(at));
        at += wide ? 4 : 2;
      }
      result.references.push({ type: reference.type, from, to });
    }
  }

  const iprp = child("iprp");
  if (iprp) {
    const parts = boxes(view, iprp.start, iprp.end);
    const ipco = parts.find((box) => box.type === "ipco");
    if (ipco) result.properties = boxes(view, ipco.start, ipco.end);
    for (const ipma of parts.filter((box) => box.type === "ipma")) {
      const version = view.getUint8(ipma.start), flags = view.getUint8(ipma.start + 3);
      let at = ipma.start + 4;
      const count = view.getUint32(at);
      at += 4;
      for (let i = 0; i < count; i++) {
        const id = version < 1 ? view.getUint16(at) : view.getUint32(at);
        at += version < 1 ? 2 : 4;
        const n = view.getUint8(at++);
        const list = result.associations.get(id) ?? [];
        for (let j = 0; j < n; j++) {
          const index = flags & 1 ? view.getUint16(at) & 0x7fff : view.getUint8(at) & 0x7f;
          at += flags & 1 ? 2 : 1;
          if (index > 0) list.push(index - 1);
        }
        result.associations.set(id, list);
      }
    }
  }
  return { view, bytes, ...result };
}

/** An item's data, its extents joined. */
function itemData(heif, id) {
  const location = heif.locations.get(id);
  if (!location) throw new Error(`No data for item ${id}`);
  const source = location.method === 1 ? heif.idat : heif.bytes;
  if (!source) throw new Error("No item data box");
  const total = location.extents.reduce((sum, extent) => sum + extent.length, 0);
  const data = new Uint8Array(total);
  let at = 0;
  for (const extent of location.extents) {
    data.set(source.subarray(extent.offset, extent.offset + extent.length), at);
    at += extent.length;
  }
  return data;
}

/** An item's properties, in the order they apply. */
function properties(heif, id) {
  return (heif.associations.get(id) ?? []).map((index) => heif.properties[index]).filter(Boolean);
}

/** The WebCodecs codec string for an HEVC decoder configuration record (ISO/IEC 14496-15, annex E). */
function codecString(hvcC) {
  const space = ["", "A", "B", "C"][hvcC[1] >> 6];
  const tier = hvcC[1] & 0x20 ? "H" : "L";
  const profile = hvcC[1] & 0x1f;
  let compatibility = (hvcC[2] << 24 | hvcC[3] << 16 | hvcC[4] << 8 | hvcC[5]) >>> 0;
  let reversed = 0;
  for (let i = 0; i < 32; i++) {
    reversed = (reversed << 1 | compatibility & 1) >>> 0;
    compatibility >>>= 1;
  }
  const constraints = [...hvcC.subarray(6, 12)];
  while (constraints.length && constraints.at(-1) === 0) constraints.pop();
  return [`hvc1.${space}${profile}`, reversed.toString(16).toUpperCase(), `${tier}${hvcC[12]}`, ...constraints.map((byte) => byte.toString(16).toUpperCase())].join(".");
}

/** The tiles to decode and how they are laid out: one for a single image, a grid's worth otherwise. */
function layout(heif) {
  const primary = heif.primary;
  const type = heif.types.get(primary);
  const tileSize = (id) => {
    const ispe = properties(heif, id).find((box) => box.type === "ispe");
    return ispe ? { width: heif.view.getUint32(ispe.start + 4), height: heif.view.getUint32(ispe.start + 8) } : null;
  };
  if (type === "hvc1") {
    const size = tileSize(primary);
    if (!size) throw new Error("No image size");
    return { tiles: [primary], columns: 1, ...size, tile: size };
  }
  if (type !== "grid") throw new Error(`Unsupported HEIF item ${type}`);
  const data = itemData(heif, primary);
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const wide = data[1] & 1;
  const rows = data[2] + 1, columns = data[3] + 1;
  const width = wide ? view.getUint32(4) : view.getUint16(4);
  const height = wide ? view.getUint32(8) : view.getUint16(6);
  const tiles = heif.references.find((reference) => reference.type === "dimg" && reference.from === primary)?.to ?? [];
  if (tiles.length !== rows * columns) throw new Error("Grid tiles missing");
  const tile = tileSize(tiles[0]);
  if (!tile) throw new Error("No tile size");
  return { tiles, columns, width, height, tile };
}

/**
 * The photo decoded with WebCodecs, turned and mirrored as the file says:
 * { width, height, data } with straight RGBA. Throws if this browser can't.
 */
export async function decodeHEIC(bytes) {
  if (typeof VideoDecoder === "undefined") throw new Error("No WebCodecs");
  const heif = readHEIF(bytes);
  const { tiles, columns, width, height, tile } = layout(heif);
  const canvas = new OffscreenCanvas(width, height);
  const context = canvas.getContext("2d");

  // Tiles usually share one configuration; a new one starts a new decoder.
  let decoder = null, configured = null, failure = null;
  const placed = [];
  const place = (frame, index) => {
    const x = (index % columns) * tile.width, y = Math.floor(index / columns) * tile.height;
    context.drawImage(frame, 0, 0, tile.width, tile.height, x, y, tile.width, tile.height);
    frame.close();
  };
  for (let index = 0; index < tiles.length; index++) {
    const hvcC = properties(heif, tiles[index]).find((box) => box.type === "hvcC");
    if (!hvcC) throw new Error("No HEVC configuration");
    const description = bytes.slice(hvcC.start, hvcC.end);
    const key = description.join(",");
    if (key !== configured) {
      if (decoder) await decoder.flush();
      decoder?.close();
      decoder = new VideoDecoder({
        output: (frame) => place(frame, placed.shift()),
        error: (error) => { failure = error; },
      });
      decoder.configure({ codec: codecString(description), description, optimizeForLatency: true });
      configured = key;
    }
    placed.push(index);
    decoder.decode(new EncodedVideoChunk({ type: "key", timestamp: index, data: itemData(heif, tiles[index]) }));
    if (failure) break;
  }
  if (decoder) {
    if (!failure) await decoder.flush().catch((error) => { failure = error; });
    decoder.close();
  }
  if (failure) throw failure;

  return transformed(canvas, properties(heif, heif.primary), heif.view);
}

/** The picture turned (irot) and mirrored (imir) as its properties say, in their order, as pixels. */
function transformed(source, props, view) {
  let canvas = source;
  for (const box of props) {
    if (box.type !== "irot" && box.type !== "imir") continue;
    const turns = box.type === "irot" ? view.getUint8(box.start) & 3 : 0;
    const swap = turns % 2 === 1;
    const next = new OffscreenCanvas(swap ? canvas.height : canvas.width, swap ? canvas.width : canvas.height);
    const context = next.getContext("2d");
    context.translate(next.width / 2, next.height / 2);
    if (box.type === "irot") {
      // Anticlockwise quarter turns.
      context.rotate((-turns * Math.PI) / 2);
    } else if (view.getUint8(box.start) & 1) {
      context.scale(1, -1);
    } else {
      context.scale(-1, 1);
    }
    context.drawImage(canvas, -canvas.width / 2, -canvas.height / 2);
    canvas = next;
  }
  const { data } = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height);
  return { width: canvas.width, height: canvas.height, data };
}
