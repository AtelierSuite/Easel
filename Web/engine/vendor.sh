#!/bin/bash
# Fetches the C libraries the engine links on the web, where Apple's SDK
# doesn't provide them, into Web/engine/swift/Sources (not checked in):
#
#   zlib      zlib 1.3.1, for PSD, PNG and zip compression (Apple's libz)
#   SQLite3   SQLite 3.54.1, for Pixelmator Pro documents (Apple's libsqlite3)
#
# Run by build.sh; does nothing once both are there.
set -euo pipefail

SOURCES="$(cd "$(dirname "$0")" && pwd)/swift/Sources"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
SQLITE_URL="https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip"
SQLITE_SHA256="0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9"

if command -v sha256sum > /dev/null; then SHA256="sha256sum"; else SHA256="shasum -a 256"; fi
fetch() {
    curl -fsSL "$1" -o "$2"
    if [[ "$($SHA256 "$2" | cut -d' ' -f1)" != "$3" ]]; then
        echo "Checksum mismatch for $1" >&2
        exit 1
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "$SOURCES/zlib/include/zlib.h" ]]; then
    echo "Fetching zlib…"
    fetch "$ZLIB_URL" "$WORK/zlib.tar.gz" "$ZLIB_SHA256"
    tar -xzf "$WORK/zlib.tar.gz" -C "$WORK"
    mkdir -p "$SOURCES/zlib/include"
    cp "$WORK"/zlib-1.3.1/*.c "$WORK"/zlib-1.3.1/*.h "$SOURCES/zlib/"
    mv "$SOURCES/zlib/zlib.h" "$SOURCES/zlib/zconf.h" "$SOURCES/zlib/include/"
fi

if [[ ! -f "$SOURCES/SQLite3/include/sqlite3.h" ]]; then
    echo "Fetching SQLite…"
    fetch "$SQLITE_URL" "$WORK/sqlite.zip" "$SQLITE_SHA256"
    unzip -q "$WORK/sqlite.zip" -d "$WORK"
    mkdir -p "$SOURCES/SQLite3/include"
    cp "$WORK"/sqlite-amalgamation-3540100/sqlite3.c "$SOURCES/SQLite3/"
    cp "$WORK"/sqlite-amalgamation-3540100/sqlite3.h "$SOURCES/SQLite3/include/"
fi
