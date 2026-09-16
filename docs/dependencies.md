# Dependency sources and pins

A clean checkout is self-contained after `bash scripts/setup.sh`. Dependency sources
and toolchains are ignored under `.work/`. Both Cargo and npm dependency graphs are
locked.

## Direct checkouts

| Component | Source / branch | Commit | Local changes or purpose |
| --- | --- | --- | --- |
| pumpkin | [master](https://github.com/Pumpkin-MC/Pumpkin) | `b5b9b9d7010e793806a83c495af223c67e1d35ee` | Headless embedding, shared async scheduler, restartable stop signal, compact templates/generation chunks, and build-script fixes |
| tokio | [emscripten-event-loop-host](https://github.com/guybedford/tokio) | `067f92b60cbba5c9fea585806af4b07fd838427e` | `LocalEventLoop` (tokio-rs/tokio#8484) and `net` over epoll on Emscripten; unmodified. |
| workers-rs | [gbedford/worker-build-emscripten](https://github.com/cloudflare/workers-rs/pull/1061) | `f4546f5379a933fbf3607bce205a8b372811d465` | cloudflare/workers-rs#1061: the `worker` crate and `worker-build --emscripten --tokio`; its `wasm-bindgen` submodule ([gbedford/emscripten-stack](https://github.com/wasm-bindgen/wasm-bindgen) `d48e82c4b3f7a182223fb1b1c7b99f59cf9b7c17`) carries `#[wasm_bindgen(tokio)]` (wasm-bindgen/wasm-bindgen#5334) and supplies every wasm-bindgen crate; unmodified |
| emscripten | [cf-final](https://github.com/guybedford/emscripten) | `462303990a2f62e2c065dcc3ba0794cb7bb2e6c4` | Upstream main plus emscripten-core/emscripten#27547 (epoll listeners on the host loop), #27742 (async DNS lookup) and #27724 (blocking accept under pthreads); unmodified |
| emsdk | [main](https://github.com/emscripten-core/emsdk) | `5eb0bde7585670252e8ba05e9d361627bffd08b5` | LLVM, Binaryen and Node from emscripten-releases build `8324e94759a0292e342577007021b4b47106333b`, paired with the frontend's main |

Patches are relative to the pinned commits above. Setup checks reverse application
before applying a patch and refuses to repin a modified checkout.

Pumpkin has two patches: `pumpkin-emscripten.patch` for embedding/runtime support,
followed by `pumpkin-memory.patch` for compact templates and generation chunks.
They currently modify separate files and are both based on the pinned upstream
commit.

## Cargo-managed forks

| Crate | Source | Purpose |
| --- | --- | --- |
| mio | https://github.com/guybedford/mio branch `emscripten` | Emscripten epoll selector (tokio-rs/mio#1969) |
| libc | https://github.com/rust-lang/libc branch `libc-0.2` | Emscripten epoll bindings, unreleased |
| ring | https://github.com/guybedford/ring branch `emscripten` | getrandom-backed `SystemRandom` on Emscripten |
| wasm-streams | https://github.com/guybedford/wasm-streams branch `rlib-only` | MattiasBuelens/wasm-streams#40; a `worker` dependency that must not also link a cdylib |

The root Cargo.toml applies these overrides and the local checkouts, and
patches the wasm-bindgen crates to the workers-rs submodule so the `worker`
crate and the application share one wasm-bindgen. Cargo.lock pins the full
application graph, including the branch commits.

## Host tools

- Rust: `beta` channel (1.99; `OwnedFd::try_clone` on Emscripten), target
  `wasm32-unknown-emscripten`; setup installs both through rustup. rustc needs a
  larger compile-thread stack for pumpkin-data's generated tables; the scripts
  set `RUST_MIN_STACK`.
- worker-build: built by setup from the workers-rs checkout into `.work/bin/`.
  It drives cargo and emcc with the common link settings, wraps the exports
  into the entrypoint and Durable Object classes, and emits `build/`.
- wasm-bindgen CLI: the release matching the `wasm-bindgen` crate version in
  Cargo.toml, installed by setup into `.work/bin/`; worker-build is pointed at
  it with `WASM_BINDGEN_BIN`. emcc runs it as a post-link step under
  `-sWASM_BINDGEN`.
- Node: 24+; 26 recommended and selected in CI. Used for build tools and tests.
- Python: 3.11+ (Emscripten scripts, emsdk and TOML parsing).
- Emscripten backend: LLVM, Binaryen and Node through emsdk under `.work/emsdk`
  (or an activated emsdk selected with `EMSDK`). `scripts/common.sh` hands the
  frontend checkout and emsdk to worker-build through `EMSCRIPTEN` and `EMSDK`;
  it uses the frontend unpatched.
- workerd: Wrangler must run a workerd with `net.Server` inbound routing into
  Durable Objects (`handleAsNodeConnection`, cloudflare/workerd#7306, #7313) and
  the `node:fs` fixes for positional buffer I/O (#7368), `O_TRUNC` (#7369),
  `O_CREAT` (#7393), and rename over an existing path (#7394). All are in
  workerd main; until Wrangler's bundled version catches up, build main
  (`bazel build //src/workerd/server:workerd`) and set `MINIFLARE_WORKERD_PATH`
  to `bazel-bin/src/workerd/server/workerd`.

## Updating a patch

Edit the relevant checkout, then generate a replacement diff against the documented
upstream base from the repository root. Write it under `.work/` to preserve the
commit description at the top of the maintained patch:

```sh
git -C .work/pumpkin add -N crates/pumpkin/src/net/bedrock/nethernet_stub.rs
git -C .work/pumpkin diff b5b9b9d7010e793806a83c495af223c67e1d35ee -- \
  . ':(exclude)Cargo.lock' ':(exclude)crates/pumpkin-world/src/generation' \
  > .work/pumpkin-emscripten.diff
git -C .work/pumpkin diff b5b9b9d7010e793806a83c495af223c67e1d35ee -- \
  crates/pumpkin-world/src/generation > .work/pumpkin-memory.diff
```

Replace the corresponding patch's contents from its first `diff --git` line onward
with the new diff. Update the subject, description, and `Base-commit` when the scope
or pinned revision changes.

The Pumpkin path filters reflect the current separation: all memory-patch files
are under `crates/pumpkin-world/src/generation/`. Adjust the filters if that scope
changes, keeping platform support and memory optimizations in their own patches.

`git diff` omits untracked files, including files created by existing patches;
`add -N` above includes `nethernet_stub.rs`. If you add a file in a dependency
checkout, include it the same way and verify application on a fresh copy of the
base. Run `bash scripts/test.sh` after runtime changes. Keep unpatched checkouts
unmodified. Setup refuses to repin a modified checkout rather than discarding
local work.

For source/patch validation without provisioning the toolchain:

```sh
bash scripts/setup.sh --sources-only
```

## JavaScript dependencies

`package-lock.json` pins Wrangler 4.129.0. There is no application JavaScript;
worker-build generates `build/index.js`, which wraps the exports into the
entrypoint and derives the Durable Object class from `DurableObject` for RPC.

After moving a checkout with cached build output, run `cargo clean` before rebuilding.
Generated data can contain absolute paths. This leaves databases under `.data/` intact.
