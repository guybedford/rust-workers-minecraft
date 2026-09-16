#!/usr/bin/env bash
# Clone pinned sources, apply dependency patches, and provision the toolchain.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --sources-only ]; }; then
  echo "usage: bash scripts/setup.sh [--sources-only]" >&2
  exit 2
fi
require_node
mkdir -p "$WORK"

checkout() { # name url branch commit
  local name="$1" url="$2" branch="$3" commit="$4" dir="$WORK/$1"
  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    if [ -e "$dir" ]; then
      echo "error: $dir exists but is not a Git checkout." >&2
      exit 1
    fi
    git clone --filter=blob:none --branch "$branch" --single-branch "$url" "$dir"
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      echo "error: refusing to repin modified checkout $dir; preserve your changes first." >&2
      exit 1
    fi
    if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
      git -C "$dir" fetch --filter=blob:none origin "$branch"
    fi
    git -C "$dir" switch --detach "$commit"
  fi
  echo "  $name @ $commit"
}

apply_patch() {
  local dir="$WORK/$1" patch="$REPO/patches/$2"
  if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
    echo "  already applied: $2"
  else
    git -C "$dir" apply --check "$patch"
    git -C "$dir" apply "$patch"
  fi
}

echo "==> Pinned dependencies"
checkout pumpkin https://github.com/Pumpkin-MC/Pumpkin master b5b9b9d7010e793806a83c495af223c67e1d35ee
checkout tokio https://github.com/guybedford/tokio emscripten-event-loop-host 067f92b60cbba5c9fea585806af4b07fd838427e
# cloudflare/workers-rs#1061; its wasm-bindgen submodule (wasm-bindgen/wasm-bindgen
# gbedford/emscripten-stack) supplies every wasm-bindgen crate.
checkout workers-rs https://github.com/cloudflare/workers-rs gbedford/worker-build-emscripten f4546f5379a933fbf3607bce205a8b372811d465
WASM_BINDGEN_SUBMODULE=d48e82c4b3f7a182223fb1b1c7b99f59cf9b7c17
if [ "$(git -C "$WORK/workers-rs/wasm-bindgen" rev-parse HEAD 2>/dev/null)" != "$WASM_BINDGEN_SUBMODULE" ]; then
  git -C "$WORK/workers-rs" submodule update --init wasm-bindgen
fi
apply_patch pumpkin pumpkin-emscripten.patch
apply_patch pumpkin pumpkin-memory.patch

if [ "${1:-}" = --sources-only ]; then exit 0; fi

echo "==> Rust toolchain"
RUST_CHANNEL="$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["toolchain"]["channel"])' "$REPO/rust-toolchain.toml")"
rustup toolchain install "$RUST_CHANNEL" --profile minimal --target wasm32-unknown-emscripten --no-self-update

echo "==> wasm-bindgen CLI"
WASM_BINDGEN_VERSION="$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["dependencies"]["wasm-bindgen"])' "$REPO/Cargo.toml")"
if [ "$("$BIN/wasm-bindgen" --version 2>/dev/null || true)" != "wasm-bindgen $WASM_BINDGEN_VERSION" ]; then
  cargo "+$RUST_CHANNEL" install --force --locked wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION" --root "$WORK"
fi

echo "==> worker-build"
# Built from the workers-rs checkout (cloudflare/workers-rs#1061) for the host,
# overriding the wasm target .cargo/config.toml sets for the package path.
if [ "$(cat "$BIN/.worker-build-rev" 2>/dev/null)" != "$(git -C "$WORK/workers-rs" rev-parse HEAD)" ]; then
  HOST="$(rustc "+$RUST_CHANNEL" -vV | sed -n 's/^host: //p')"
  cargo "+$RUST_CHANNEL" install --force --locked --target "$HOST" --path "$WORK/workers-rs/worker-build" --root "$WORK"
  git -C "$WORK/workers-rs" rev-parse HEAD > "$BIN/.worker-build-rev"
fi

echo "==> Emscripten"
# Frontend: upstream main plus the pending epoll listener PR. The backend (LLVM, Binaryen, Node) is the emscripten-releases build
# the frontend's main is paired with, installed through emsdk; EMSDK selects an
# activated emsdk instead. worker-build reads both from EMSCRIPTEN and EMSDK
# (scripts/common.sh) and uses the frontend unpatched.
EMSDK_RELEASE=8324e94759a0292e342577007021b4b47106333b
checkout emscripten https://github.com/guybedford/emscripten cf-final 462303990a2f62e2c065dcc3ba0794cb7bb2e6c4
NODE_PATH="$("$NODE" -p 'process.execPath')"
(cd "$EMSCRIPTEN" && PATH="$(dirname "$NODE_PATH"):$PATH" npm ci --no-audit --no-fund && python3 bootstrap.py)
if [ -z "${EMSDK:-}" ]; then
  checkout emsdk https://github.com/emscripten-core/emsdk main 5eb0bde7585670252e8ba05e9d361627bffd08b5
  if [ "$(cat "$WORK/emsdk/upstream/.emsdk_version" 2>/dev/null)" != "releases-$EMSDK_RELEASE-64bit" ]; then
    (cd "$WORK/emsdk" && ./emsdk install "$EMSDK_RELEASE" && ./emsdk activate "$EMSDK_RELEASE")
  fi
  EMSDK="$WORK/emsdk"
fi
if [ ! -x "$EMSDK/upstream/bin/clang" ] || [ ! -x "$EMSDK/upstream/bin/wasm-opt" ]; then
  echo "error: no Emscripten backend at EMSDK=$EMSDK." >&2
  exit 1
fi
echo "Setup complete. Run: bash scripts/test.sh  or  bash scripts/serve.sh"
