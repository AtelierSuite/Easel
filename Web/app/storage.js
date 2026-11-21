// What Easel keeps on this device: recently opened files, with their file
// handles where the browser can keep them, and otherwise a copy of what was
// opened (a dropped file, a folder, a pick from a plain file input), so Open
// Recent can open them again.
//
// Records live in IndexedDB; kept copies in the origin private file system,
// falling back to IndexedDB where that isn't available.

const DATABASE = "easel";
const VERSION = 1;

function open() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("documents")) db.createObjectStore("documents", { keyPath: "id" });
      if (!db.objectStoreNames.contains("blobs")) db.createObjectStore("blobs");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

let database = null;
async function db() {
  database ??= await open();
  return database;
}

function transaction(store, mode, body) {
  return db().then((connection) => new Promise((resolve, reject) => {
    const tx = connection.transaction(store, mode);
    const result = body(tx.objectStore(store));
    tx.oncomplete = () => resolve(result?.result ?? result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  }));
}

/**
 * @typedef {object} DocumentRecord
 * @property {string} id
 * @property {string} name        the file name shown
 * @property {number} openedAt
 * @property {boolean} [kept]    a copy of the bytes is kept (readCopy)
 * @property {boolean} [isPackage] the bytes are a package folder, zipped
 * @property {FileSystemFileHandle} [handle]
 */

/** @returns {Promise<DocumentRecord[]>} newest first */
export async function recentDocuments() {
  try {
    const records = await transaction("documents", "readonly", (store) => store.getAll());
    return records.sort((a, b) => b.openedAt - a.openedAt);
  } catch {
    return [];
  }
}

export async function saveRecord(record) {
  try {
    await transaction("documents", "readwrite", (store) => store.put(record));
  } catch {
    // Storage may be unavailable (private browsing); recents are a convenience.
  }
}

export async function removeRecord(id) {
  try {
    await transaction("documents", "readwrite", (store) => store.delete(id));
    await removeCopy(id);
  } catch {
    // Nothing to remove.
  }
}

export async function clearRecents() {
  for (const record of await recentDocuments()) await removeRecord(record.id);
}

async function copiesFolder() {
  const root = await navigator.storage?.getDirectory?.();
  return root ? root.getDirectoryHandle("copies", { create: true }) : null;
}

/** Keeps a copy of a document's bytes. */
export async function writeCopy(id, bytes) {
  try {
    const folder = await copiesFolder();
    if (folder) {
      const file = await folder.getFileHandle(id, { create: true });
      const writable = await file.createWritable();
      await writable.write(bytes);
      await writable.close();
      return true;
    }
  } catch {
    // Fall through to IndexedDB (Safari's private file system has no createWritable before 17.4 in windows).
  }
  try {
    await transaction("blobs", "readwrite", (store) => store.put(new Blob([bytes]), id));
    return true;
  } catch {
    return false;
  }
}

/** @returns {Promise<Uint8Array | null>} */
export async function readCopy(id) {
  try {
    const folder = await copiesFolder();
    if (folder) {
      const file = await (await folder.getFileHandle(id)).getFile();
      return new Uint8Array(await file.arrayBuffer());
    }
  } catch {
    // Try IndexedDB.
  }
  try {
    const blob = await transaction("blobs", "readonly", (store) => store.get(id));
    return blob ? new Uint8Array(await blob.arrayBuffer()) : null;
  } catch {
    return null;
  }
}

export async function removeCopy(id) {
  try {
    const folder = await copiesFolder();
    await folder?.removeEntry(id);
  } catch {
    // Already gone.
  }
  try {
    await transaction("blobs", "readwrite", (store) => store.delete(id));
  } catch {
    // Already gone.
  }
}

/** Asks the browser not to evict what Easel keeps, once there is something worth keeping. */
export async function persist() {
  try {
    if (navigator.storage?.persisted && !(await navigator.storage.persisted())) await navigator.storage.persist();
  } catch {
    // Best effort.
  }
}
