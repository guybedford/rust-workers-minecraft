#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$REPO/.work"
NODE="${NODE:-node}"
# Setup provisions the Emscripten frontend and backend and the worker-build and
# wasm-bindgen CLIs under .work/. worker-build reads the toolchain from
# EMSCRIPTEN, EMSDK and WASM_BINDGEN_BIN.
EMSCRIPTEN="$WORK/emscripten"
BIN="$WORK/bin"

require_node() {
  local major
  major="$("$NODE" -p 'process.versions.node.split(".")[0]')"
  if [ "$major" -lt 24 ]; then
    echo "error: Node >= 24 required. Select it or set NODE=/path/to/node." >&2
    exit 1
  fi
}

require_toolchain() {
  if [ ! -x "$EMSCRIPTEN/emcc" ] ||
     [ ! -x "$BIN/worker-build" ] ||
     [ ! -x "$BIN/wasm-bindgen" ] ||
     [ ! -f "$WORK/pumpkin/crates/pumpkin/Cargo.toml" ] ||
     [ ! -f "$WORK/tokio/tokio/Cargo.toml" ] ||
     [ ! -f "$WORK/workers-rs/worker/Cargo.toml" ]; then
    echo "error: run bash scripts/setup.sh first." >&2
    exit 1
  fi
  export EMSCRIPTEN
  export EMSDK="${EMSDK:-$WORK/emsdk}"
  export WASM_BINDGEN_BIN="$BIN/wasm-bindgen"
  export PATH="$BIN:$PATH"
  export CARGO_TARGET_DIR="$REPO/target/workers"
  # rustc's LLVM const emission recurses deeply on pumpkin-data's generated tables
  # and overflows its default 8 MiB compile-thread stack on current toolchains.
  export RUST_MIN_STACK="${RUST_MIN_STACK:-268435456}"
}

require_packages() {
  if [ ! -f "$REPO/node_modules/wrangler/bin/wrangler.js" ]; then
    echo "error: run npm ci first." >&2
    exit 1
  fi
}
