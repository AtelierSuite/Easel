// A minimal WASI preview 1 host for the Easel engine, with no dependencies.
//
// Documents arrive as bytes through the engine API, but some of Paintbrush
// goes through files on the way (Pixelmator Pro documents are SQLite
// databases, which SQLite opens by path). So besides clocks, randomness,
// environment and stdout/stderr, this host keeps a small file system in
// memory, rooted at "/", that's emptied when the page closes.

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_EXIST = 20;
const ERRNO_INVAL = 28;
const ERRNO_ISDIR = 31;
const ERRNO_NOENT = 44;
const ERRNO_NOSYS = 52;
const ERRNO_NOTDIR = 54;
const ERRNO_NOTEMPTY = 55;

const FILETYPE_CHARACTER_DEVICE = 2;
const FILETYPE_DIRECTORY = 3;
const FILETYPE_REGULAR_FILE = 4;

const OFLAGS_CREAT = 1;
const OFLAGS_DIRECTORY = 2;
const OFLAGS_EXCL = 4;
const OFLAGS_TRUNC = 8;
const FDFLAGS_APPEND = 1;

const ROOT_FD = 3;

export class WASIExit extends Error {
  constructor(code) {
    super(`WASI exit ${code}`);
    this.code = code;
  }
}

class MemoryFile {
  constructor() {
    this.data = new Uint8Array(0);
    this.size = 0;
    this.modified = Date.now();
  }

  reserve(size) {
    if (size <= this.data.length) return;
    const grown = new Uint8Array(Math.max(size, this.data.length * 2, 4096));
    grown.set(this.data.subarray(0, this.size));
    this.data = grown;
  }

  write(bytes, position) {
    this.reserve(position + bytes.length);
    this.data.set(bytes, position);
    this.size = Math.max(this.size, position + bytes.length);
    this.modified = Date.now();
  }

  truncate(size) {
    this.reserve(size);
    if (size > this.size) this.data.fill(0, this.size, size);
    this.size = size;
    this.modified = Date.now();
  }
}

export class WASIHost {
  /**
   * @param {object} options
   * @param {string[]} [options.args]
   * @param {Record<string, string>} [options.env]
   * @param {(text: string) => void} [options.stdout]
   * @param {(text: string) => void} [options.stderr]
   */
  constructor({ args = ["easel"], env = {}, stdout = (t) => console.log(t), stderr = (t) => console.warn(t) } = {}) {
    this.args = args;
    this.env = Object.entries({ TMPDIR: "/tmp", HOME: "/home", ...env }).map(([k, v]) => `${k}=${v}`);
    this.sinks = { 1: stdout, 2: stderr };
    this.pending = { 1: "", 2: "" };
    this.memory = null;
    this.encoder = new TextEncoder();
    this.decoder = new TextDecoder();
    /** @type {Map<string, MemoryFile | "directory">} paths without a leading slash; "" is the root */
    this.files = new Map([["", "directory"], ["tmp", "directory"], ["home", "directory"]]);
    /** @type {Map<number, { path: string, position: number, append: boolean, entries?: string[] }>} */
    this.descriptors = new Map([[ROOT_FD, { path: "", position: 0, append: false }]]);
    this.nextFD = ROOT_FD + 1;
  }

  /** Call once the instance exists, before running anything. */
  bind(instance) {
    this.memory = instance.exports.memory;
  }

  get view() {
    return new DataView(this.memory.buffer);
  }

  get bytes() {
    return new Uint8Array(this.memory.buffer);
  }

  writeStrings(strings, pointersPtr, bufferPtr) {
    const view = this.view;
    const bytes = this.bytes;
    let offset = bufferPtr;
    strings.forEach((string, index) => {
      view.setUint32(pointersPtr + index * 4, offset, true);
      const encoded = this.encoder.encode(string);
      bytes.set(encoded, offset);
      bytes[offset + encoded.length] = 0;
      offset += encoded.length + 1;
    });
    return ERRNO_SUCCESS;
  }

  sizeStrings(strings, countPtr, sizePtr) {
    const view = this.view;
    view.setUint32(countPtr, strings.length, true);
    view.setUint32(sizePtr, strings.reduce((sum, s) => sum + this.encoder.encode(s).length + 1, 0), true);
    return ERRNO_SUCCESS;
  }

  emit(fd, text) {
    const lines = (this.pending[fd] + text).split("\n");
    this.pending[fd] = lines.pop();
    for (const line of lines) this.sinks[fd](line);
  }

  flush() {
    for (const fd of [1, 2]) {
      if (this.pending[fd]) this.sinks[fd](this.pending[fd]);
      this.pending[fd] = "";
    }
  }

  readString(pointer, length) {
    return this.decoder.decode(new Uint8Array(this.memory.buffer, pointer, length));
  }

  /** A path relative to a directory descriptor, normalised, without a leading slash. */
  resolve(dirFD, pointer, length) {
    const base = this.descriptors.get(dirFD);
    if (!base) return null;
    const raw = this.readString(pointer, length);
    const parts = raw.startsWith("/") ? [] : base.path.split("/").filter(Boolean);
    for (const part of raw.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") parts.pop();
      else parts.push(part);
    }
    return parts.join("/");
  }

  parentExists(path) {
    const parent = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
    return this.files.get(parent) === "directory";
  }

  writeFilestat(pointer, entry) {
    new Uint8Array(this.memory.buffer, pointer, 64).fill(0);
    const view = this.view;
    const isDirectory = entry === "directory";
    view.setUint8(pointer + 16, isDirectory ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
    view.setBigUint64(pointer + 24, 1n, true);
    view.setBigUint64(pointer + 32, BigInt(isDirectory ? 0 : entry.size), true);
    const time = BigInt(isDirectory ? Date.now() : entry.modified) * 1_000_000n;
    view.setBigUint64(pointer + 40, time, true);
    view.setBigUint64(pointer + 48, time, true);
    view.setBigUint64(pointer + 56, time, true);
  }

  /** Each iovec as a view into memory. */
  iovecs(iovs, count) {
    const view = this.view;
    const list = [];
    for (let i = 0; i < count; i++) {
      list.push(new Uint8Array(this.memory.buffer, view.getUint32(iovs + i * 8, true), view.getUint32(iovs + i * 8 + 4, true)));
    }
    return list;
  }

  get imports() {
    const host = this;
    const file = (fd) => {
      const descriptor = host.descriptors.get(fd);
      if (!descriptor) return null;
      const entry = host.files.get(descriptor.path);
      return entry instanceof MemoryFile ? { descriptor, entry } : null;
    };
    const readInto = (entry, iovs, count, position) => {
      let read = 0;
      for (const buffer of host.iovecs(iovs, count)) {
        const n = Math.max(0, Math.min(buffer.length, entry.size - position - read));
        buffer.set(entry.data.subarray(position + read, position + read + n));
        read += n;
        if (n < buffer.length) break;
      }
      return read;
    };
    const writeFrom = (entry, iovs, count, position) => {
      let written = 0;
      for (const buffer of host.iovecs(iovs, count)) {
        entry.write(buffer, position + written);
        written += buffer.length;
      }
      return written;
    };
    return {
      wasi_snapshot_preview1: {
        args_get: (argv, buf) => host.writeStrings(host.args, argv, buf),
        args_sizes_get: (count, size) => host.sizeStrings(host.args, count, size),
        environ_get: (envp, buf) => host.writeStrings(host.env, envp, buf),
        environ_sizes_get: (count, size) => host.sizeStrings(host.env, count, size),

        clock_res_get(id, resultPtr) {
          host.view.setBigUint64(resultPtr, 1000n, true);
          return ERRNO_SUCCESS;
        },
        clock_time_get(id, precision, resultPtr) {
          // 0 = realtime, 1 = monotonic; both in nanoseconds.
          const ms = id === 0 ? Date.now() : performance.now();
          const ns = id === 0 ? BigInt(ms) * 1_000_000n : BigInt(Math.round(ms * 1_000_000));
          host.view.setBigUint64(resultPtr, ns, true);
          return ERRNO_SUCCESS;
        },

        random_get(ptr, length) {
          // getRandomValues fills at most 65536 bytes per call.
          for (let offset = 0; offset < length; offset += 65536) {
            crypto.getRandomValues(new Uint8Array(host.memory.buffer, ptr + offset, Math.min(65536, length - offset)));
          }
          return ERRNO_SUCCESS;
        },

        fd_write(fd, iovs, iovsLength, writtenPtr) {
          if (fd === 1 || fd === 2) {
            let written = 0;
            let text = "";
            for (const buffer of host.iovecs(iovs, iovsLength)) {
              text += host.decoder.decode(buffer, { stream: true });
              written += buffer.length;
            }
            host.emit(fd, text);
            host.view.setUint32(writtenPtr, written, true);
            return ERRNO_SUCCESS;
          }
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          if (open.descriptor.append) open.descriptor.position = open.entry.size;
          const written = writeFrom(open.entry, iovs, iovsLength, open.descriptor.position);
          open.descriptor.position += written;
          host.view.setUint32(writtenPtr, written, true);
          return ERRNO_SUCCESS;
        },
        fd_pwrite(fd, iovs, iovsLength, offset, writtenPtr) {
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          host.view.setUint32(writtenPtr, writeFrom(open.entry, iovs, iovsLength, Number(offset)), true);
          return ERRNO_SUCCESS;
        },
        fd_read(fd, iovs, iovsLength, readPtr) {
          if (fd === 0) {
            host.view.setUint32(readPtr, 0, true);
            return ERRNO_SUCCESS;
          }
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          const read = readInto(open.entry, iovs, iovsLength, open.descriptor.position);
          open.descriptor.position += read;
          host.view.setUint32(readPtr, read, true);
          return ERRNO_SUCCESS;
        },
        fd_pread(fd, iovs, iovsLength, offset, readPtr) {
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          host.view.setUint32(readPtr, readInto(open.entry, iovs, iovsLength, Number(offset)), true);
          return ERRNO_SUCCESS;
        },
        fd_seek(fd, offset, whence, resultPtr) {
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          const base = whence === 0 ? 0 : whence === 1 ? open.descriptor.position : open.entry.size;
          const position = base + Number(offset);
          if (position < 0) return ERRNO_INVAL;
          open.descriptor.position = position;
          host.view.setBigUint64(resultPtr, BigInt(position), true);
          return ERRNO_SUCCESS;
        },
        fd_tell(fd, resultPtr) {
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          host.view.setBigUint64(resultPtr, BigInt(open.descriptor.position), true);
          return ERRNO_SUCCESS;
        },
        fd_fdstat_get(fd, statPtr) {
          const view = host.view;
          let type = FILETYPE_CHARACTER_DEVICE;
          if (fd > 2) {
            const descriptor = host.descriptors.get(fd);
            if (!descriptor) return ERRNO_BADF;
            type = host.files.get(descriptor.path) === "directory" ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE;
          }
          view.setUint8(statPtr, type);
          view.setUint16(statPtr + 2, 0, true);
          view.setBigUint64(statPtr + 8, 0xffffffffffffffffn, true);
          view.setBigUint64(statPtr + 16, 0xffffffffffffffffn, true);
          return ERRNO_SUCCESS;
        },
        fd_fdstat_set_flags: (fd) => (fd <= 2 || host.descriptors.has(fd) ? ERRNO_SUCCESS : ERRNO_BADF),
        fd_filestat_get(fd, statPtr) {
          if (fd <= 2) {
            new Uint8Array(host.memory.buffer, statPtr, 64).fill(0);
            host.view.setUint8(statPtr + 16, FILETYPE_CHARACTER_DEVICE);
            return ERRNO_SUCCESS;
          }
          const descriptor = host.descriptors.get(fd);
          const entry = descriptor && host.files.get(descriptor.path);
          if (!entry) return ERRNO_BADF;
          host.writeFilestat(statPtr, entry);
          return ERRNO_SUCCESS;
        },
        fd_filestat_set_size(fd, size) {
          const open = file(fd);
          if (!open) return ERRNO_BADF;
          open.entry.truncate(Number(size));
          return ERRNO_SUCCESS;
        },
        fd_filestat_set_times: () => ERRNO_SUCCESS,
        fd_close(fd) {
          if (fd <= 2) return ERRNO_SUCCESS;
          if (fd === ROOT_FD) return ERRNO_SUCCESS;
          return host.descriptors.delete(fd) ? ERRNO_SUCCESS : ERRNO_BADF;
        },
        fd_sync: () => ERRNO_SUCCESS,
        fd_datasync: () => ERRNO_SUCCESS,
        fd_advise: () => ERRNO_SUCCESS,
        fd_allocate: () => ERRNO_SUCCESS,
        fd_readdir(fd, bufPtr, bufLength, cookie, usedPtr) {
          const descriptor = host.descriptors.get(fd);
          if (!descriptor || host.files.get(descriptor.path) !== "directory") return ERRNO_BADF;
          const prefix = descriptor.path ? `${descriptor.path}/` : "";
          const names = [...host.files.keys()].filter((p) => p.startsWith(prefix) && p !== descriptor.path && !p.slice(prefix.length).includes("/"));
          let used = 0;
          const view = host.view;
          for (let index = Number(cookie); index < names.length; index++) {
            const name = host.encoder.encode(names[index].slice(prefix.length));
            const entry = host.files.get(names[index]);
            const header = new Uint8Array(24);
            const headerView = new DataView(header.buffer);
            headerView.setBigUint64(0, BigInt(index + 1), true);
            headerView.setBigUint64(8, BigInt(index + 1), true);
            headerView.setUint32(16, name.length, true);
            headerView.setUint8(20, entry === "directory" ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
            const record = new Uint8Array(24 + name.length);
            record.set(header);
            record.set(name, 24);
            const n = Math.min(record.length, bufLength - used);
            host.bytes.set(record.subarray(0, n), bufPtr + used);
            used += n;
            if (used >= bufLength) break;
          }
          view.setUint32(usedPtr, used, true);
          return ERRNO_SUCCESS;
        },
        fd_renumber: () => ERRNO_NOSYS,
        fd_prestat_get(fd, ptr) {
          if (fd !== ROOT_FD) return ERRNO_BADF;
          host.view.setUint8(ptr, 0);
          host.view.setUint32(ptr + 4, 1, true);
          return ERRNO_SUCCESS;
        },
        fd_prestat_dir_name(fd, ptr, length) {
          if (fd !== ROOT_FD) return ERRNO_BADF;
          if (length >= 1) host.bytes[ptr] = 0x2f;
          return ERRNO_SUCCESS;
        },
        path_open(dirFD, dirflags, pathPtr, pathLength, oflags, rightsBase, rightsInheriting, fdflags, fdPtr) {
          const path = host.resolve(dirFD, pathPtr, pathLength);
          if (path === null) return ERRNO_BADF;
          let entry = host.files.get(path);
          if (entry && oflags & OFLAGS_EXCL && oflags & OFLAGS_CREAT) return ERRNO_EXIST;
          if (!entry) {
            if (!(oflags & OFLAGS_CREAT)) return ERRNO_NOENT;
            if (!host.parentExists(path)) return ERRNO_NOENT;
            entry = new MemoryFile();
            host.files.set(path, entry);
          }
          if (oflags & OFLAGS_DIRECTORY && entry !== "directory") return ERRNO_NOTDIR;
          if (entry instanceof MemoryFile && oflags & OFLAGS_TRUNC) entry.truncate(0);
          const fd = host.nextFD++;
          host.descriptors.set(fd, { path, position: 0, append: Boolean(fdflags & FDFLAGS_APPEND) });
          host.view.setUint32(fdPtr, fd, true);
          return ERRNO_SUCCESS;
        },
        path_filestat_get(dirFD, flags, pathPtr, pathLength, statPtr) {
          const path = host.resolve(dirFD, pathPtr, pathLength);
          const entry = path === null ? null : host.files.get(path);
          if (!entry) return ERRNO_NOENT;
          host.writeFilestat(statPtr, entry);
          return ERRNO_SUCCESS;
        },
        path_filestat_set_times: () => ERRNO_SUCCESS,
        path_create_directory(dirFD, pathPtr, pathLength) {
          const path = host.resolve(dirFD, pathPtr, pathLength);
          if (path === null) return ERRNO_BADF;
          if (host.files.has(path)) return ERRNO_EXIST;
          if (!host.parentExists(path)) return ERRNO_NOENT;
          host.files.set(path, "directory");
          return ERRNO_SUCCESS;
        },
        path_remove_directory(dirFD, pathPtr, pathLength) {
          const path = host.resolve(dirFD, pathPtr, pathLength);
          if (host.files.get(path) !== "directory") return ERRNO_NOTDIR;
          if ([...host.files.keys()].some((p) => p.startsWith(`${path}/`))) return ERRNO_NOTEMPTY;
          host.files.delete(path);
          return ERRNO_SUCCESS;
        },
        path_unlink_file(dirFD, pathPtr, pathLength) {
          const path = host.resolve(dirFD, pathPtr, pathLength);
          const entry = host.files.get(path);
          if (!entry) return ERRNO_NOENT;
          if (entry === "directory") return ERRNO_ISDIR;
          host.files.delete(path);
          return ERRNO_SUCCESS;
        },
        path_rename(fromFD, fromPtr, fromLength, toFD, toPtr, toLength) {
          const from = host.resolve(fromFD, fromPtr, fromLength);
          const to = host.resolve(toFD, toPtr, toLength);
          const entry = host.files.get(from);
          if (!entry) return ERRNO_NOENT;
          host.files.delete(from);
          host.files.set(to, entry);
          return ERRNO_SUCCESS;
        },
        path_link: () => ERRNO_NOSYS,
        path_symlink: () => ERRNO_NOSYS,
        path_readlink: () => ERRNO_INVAL,
        poll_oneoff: () => ERRNO_NOSYS,
        sched_yield: () => ERRNO_SUCCESS,
        proc_raise: () => ERRNO_NOSYS,
        sock_accept: () => ERRNO_NOSYS,
        sock_recv: () => ERRNO_NOSYS,
        sock_send: () => ERRNO_NOSYS,
        sock_shutdown: () => ERRNO_NOSYS,
        proc_exit(code) {
          host.flush();
          throw new WASIExit(code);
        },
      },
    };
  }

  /** Initialises a reactor module (one built with -mexec-model=reactor). */
  initialize(instance) {
    this.bind(instance);
    instance.exports._initialize?.();
    this.flush();
  }
}
