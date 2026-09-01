# Penpot's WebAssembly canvas renderer (the upstream `render-wasm/` tree):
# Rust compiled for wasm32-unknown-emscripten with emscripten, statically
# linking Penpot's prebuilt Skia binary distribution.
#
# Packaging notes (why this is not a plain buildRustPackage):
#
# - nixpkgs cannot cross-compile Rust for wasm32-unknown-emscripten: the
#   target is absent from `pkgsCross` and nixpkgs' `rustc` ships no std for
#   it.  The Rust toolchain is therefore assembled from the official dist
#   tarballs (version pinned to the one upstream's devenv uses), and
#   nixpkgs' emscripten provides emcc/em++/emar.  Upstream devenv pins
#   emsdk 4.0.6; nixpkgs' emscripten (6.0.8) accepts the same flag set.
# - The skia-bindings build script normally downloads a prebuilt Skia
#   tarball from GitHub at build time.  We fetch that tarball with fetchurl
#   and hand it to the build script via SKIA_BINARIES_URL=file://, so the
#   build itself runs sandboxed with no network access.
# - Cargo dependencies are vendored with rustPlatform.fetchCargoVendor
#   (itself a fixed-output derivation).  When penpot (or its
#   render-wasm/Cargo.lock) changes, recompute the hash: set it to
#   lib.fakeHash, run `nix build .#penpot-render-wasm`, and copy the
#   "got: sha256-..." value from the hash-mismatch error back into this
#   file. If the Rust toolchain version (rustVersion below) or the Skia
#   tarball URL changes, the corresponding fetchurl hashes must be
#   recomputed as well (same procedure: set to lib.fakeHash, read `got:`).
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  patchelf,
  libgcc,
  rustPlatform,
  emscripten,
  esbuild,
  zlib,
  penpot,
  version,
}:
let
  # Rust version pinned by upstream's devenv (1.91.0, released 2025-10-30).
  rustVersion = "1.91.0";
  rustDistDate = "2025-10-30";
  wasmTarget = "wasm32-unknown-emscripten";

  # Only the two systems this flake targets are wired up; the official dist
  # tarballs are host-specific, hence the per-system hashes.
  hostTriple =
    {
      x86_64-linux = "x86_64-unknown-linux-gnu";
      aarch64-linux = "aarch64-unknown-linux-gnu";
    }
    .${stdenv.hostPlatform.system}
      or (throw "penpot-render-wasm: unsupported system ${stdenv.hostPlatform.system}");

  rustDistHashes =
    {
      x86_64-linux = {
        rustc = "sha256-pxaejLYXSvL0VxdwM3A2PY3oLOVfbMuhhYkwRbk3CHQ=";
        cargo = "sha256-cQPAP7ir6FsjMHAFqd/k8ByCaomUXYS5b6LQP9TS0Tg=";
        hostStd = "sha256-ieZSCxbBK0NSZEApjS2g3LcHR8XMLQuOR9ObXamu70k=";
      };
      aarch64-linux = {
        rustc = "sha256-8+o8lkt/O4hDN/LUEXZAMrvRci1/VVkqVHy7Ka/YfAM=";
        cargo = "sha256-AD1wCCGcoNIlrR36MB98B5sSNJlDDuB4DIV4Lgh47v8=";
        hostStd = "sha256-/yPcgfeW1k406GakT9C8rnJuNAFINTabj5OTpUQWfso=";
      };
    }
    .${stdenv.hostPlatform.system};

  rustDist =
    name: hash:
    fetchurl {
      url = "https://static.rust-lang.org/dist/${rustDistDate}/${name}.tar.xz";
      inherit hash;
    };

  # Minimal rustc + cargo installation (laid out like a rustup toolchain):
  # std for the host is needed for build scripts and proc-macros, std for
  # the emscripten target for the actual build.  The dist binaries are
  # unpatched upstream builds, so the ELF files get their interpreter and
  # rpath pointed at nixpkgs' glibc/libgcc/zlib explicitly (autoPatchelfHook
  # proved unreliable for these binaries).
  rustToolchain =
    runCommand "penpot-render-wasm-rust-toolchain-${rustVersion}"
      {
        nativeBuildInputs = [ patchelf ];
        # The dist binaries ship pre-stripped; stripping them corrupts them.
        dontStrip = true;
      }
      ''
        mkdir -p $out
        tar -xJf ${rustDist "rustc-${rustVersion}-${hostTriple}" rustDistHashes.rustc} \
          --strip-components=2 -C $out "rustc-${rustVersion}-${hostTriple}/rustc"
        tar -xJf ${rustDist "cargo-${rustVersion}-${hostTriple}" rustDistHashes.cargo} \
          --strip-components=2 -C $out "cargo-${rustVersion}-${hostTriple}/cargo"
        tar -xJf ${rustDist "rust-std-${rustVersion}-${hostTriple}" rustDistHashes.hostStd} \
          --strip-components=2 -C $out "rust-std-${rustVersion}-${hostTriple}/rust-std-${hostTriple}"
        tar -xJf ${rustDist "rust-std-${rustVersion}-${wasmTarget}" "sha256-0oJ49jPVYxTJAE058YHy1vz7kdqXSTgOsp9Hzo+Bfk4="} \
          --strip-components=2 -C $out "rust-std-${rustVersion}-${wasmTarget}/rust-std-${wasmTarget}"

        rpath="$out/lib:${stdenv.cc.libc}/lib:${libgcc}/lib:${zlib}/lib"
        interp="$(cat ${stdenv.cc.bintools}/nix-support/dynamic-linker)"
        find $out -type f \( \
          -path "*/bin/cargo" -o -path "*/bin/rustc" -o -path "*/bin/rustdoc" \
          -o -name "librustc_driver*.so" -o -name "libLLVM.so.*" \
          -o -name rust-analyzer-proc-macro-srv -o -path "*rustlib/*/bin/*" \
        \) -print0 | while IFS= read -r -d "" f; do
          # Skip linker scripts / completions etc. that match the globs.
          [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")" = "7f454c46" ] || continue
          if [ -n "$(patchelf --print-interpreter "$f" 2>/dev/null)" ]; then
            patchelf --set-interpreter "$interp" "$f"
          fi
          patchelf --set-rpath "$rpath" "$f"
        done

        # Fail the derivation if the toolchain cannot actually run sandboxed.
        $out/bin/cargo --version
        $out/bin/rustc --version
      '';

  # Prebuilt Skia for wasm32/emscripten, pinned by the SKIA_BINARIES_URL
  # default in penpot/render-wasm/_build_env.  Handed to the skia-bindings
  # build script, which accepts file:// URLs for exactly this purpose.
  skiaBinaries = fetchurl {
    url = "https://github.com/penpot/skia-binaries/releases/download/0.93.1/skia-binaries-319323662b1685a112f5-${wasmTarget}-gl-svg-textlayout-binary-cache-webp.tar.gz";
    hash = "sha256-kwqI/Cg2c0JrzDKOAnselx+JgSPjhn/y7wS40DpDTx0=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    name = "penpot-render-wasm-cargo-deps";
    src = penpot + "/render-wasm";
    hash = "sha256-Qxv3feKgQe/0+43rEehoRWibCJoxvOAHFDLY3Sq5jWs=";
  };

  # Common emcc flags, verbatim from penpot/render-wasm/_build_env, plus
  # -sDEFAULT_TO_CXX: the prebuilt Skia libraries are C++ objects that need
  # libc++abi at link time, which newer emcc no longer pulls in when the
  # linker is invoked as plain emcc (as rustc does).
  emccCommonFlags = [
    "-sDEFAULT_TO_CXX=1"
    "--no-entry"
    "--js-library"
    "src/js/wapi.js"
    "-sMALLOC=dlmalloc"
    "-sINVOKE_RUN=0"
    "-sALLOW_TABLE_GROWTH=0"
    "-sALLOW_MEMORY_GROWTH=1"
    "-sINITIAL_HEAP=268435456" # upstream: $((256 * 1024 * 1024))
    "-sMEMORY_GROWTH_GEOMETRIC_STEP=0.8"
    "-sERROR_ON_UNDEFINED_SYMBOLS=0"
    "-sMAX_WEBGL_VERSION=2"
    "-sEXPORT_NAME=createRustSkiaModule"
    "-sEXPORTED_RUNTIME_METHODS=GL,UTF8ToString,stringToUTF8,HEAPU8,HEAP32,HEAPU32,HEAPF32"
    # Upstream 2.17.x builds with -sENVIRONMENT=web; the extra node/worker
    # environments are only needed by the (post-2.17) wasm-based exporter.
    "-sENVIRONMENT=web"
    "-sMODULARIZE=1"
    "-sDISABLE_EXCEPTION_CATCHING=1"
    "-sFILESYSTEM=0"
    "-sEXPORT_ES6=1"
  ];

  # Builds one flavor of the renderer.  Upstream drives both flavors through
  # render-wasm/build + _build_env; the differences are the cargo profile
  # (--release vs --profile size) and the emcc optimization level.
  buildRenderWasm =
    flavor:
    assert lib.assertOneOf "flavor" flavor [
      "frontend"
      "export"
    ];
    let
      isFrontend = flavor == "frontend";
      cargoProfileFlag = if isFrontend then "--release" else "--profile size";
      profileDir = if isFrontend then "release" else "size";
    in
    stdenv.mkDerivation {
      pname = "penpot-render-wasm" + lib.optionalString (!isFrontend) "-export";
      inherit version;

      src = penpot + "/render-wasm";

      nativeBuildInputs = [
        rustToolchain
        emscripten
        esbuild
      ];

      env = {
        CARGO_BUILD_TARGET = wasmTarget;
        SKIA_BINARIES_URL = "file://${skiaBinaries}";
        EMCC_CFLAGS = lib.concatStringsSep " " (
          (if isFrontend then [ "-O3" ] else [ "-Oz" ]) ++ [ "-sASSERTIONS=0" ] ++ emccCommonFlags
        );
      };

      buildPhase = ''
        runHook preBuild

        export CARGO_TARGET_DIR="$PWD/cargo-target"
        export CARGO_HOME="$PWD/cargo-home"
        export CC_wasm32_unknown_emscripten=emcc
        export AR_wasm32_unknown_emscripten=emar

        # emcc needs a writable cache; seed it from the store copy so the
        # sysroot libraries are not rebuilt.
        export EM_CACHE="$PWD/emcc-cache"
        cp -r --reflink=auto "${emscripten}/share/emscripten/cache/." "$EM_CACHE/"
        chmod -R u+w "$EM_CACHE/"

        # Point cargo at the vendored crates; fetchCargoVendor's config
        # ships with a @vendor@ placeholder to fill in.
        cp -r --reflink=auto "${cargoDeps}" ./cargo-vendor
        chmod -R u+w ./cargo-vendor
        mkdir -p .cargo
        substitute "${cargoDeps}/.cargo/config.toml" .cargo/config.toml \
          --subst-var-by vendor "$PWD/cargo-vendor"

        ${lib.optionalString (!isFrontend) ''
                    # Penpot 2.17.2 predates the size-optimized profile that newer
                    # upstream uses for the exporter flavor; add it (same definition
                    # as current upstream render-wasm/Cargo.toml).
                    if ! grep -q "^\[profile\.size\]" Cargo.toml; then
                      cat >> Cargo.toml <<'PROFILES'

          [profile.size]
          inherits = "release"
          opt-level = "z"
          PROFILES
                    fi
        ''}

        cargo build ${cargoProfileFlag} --offline

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        artifacts="$PWD/cargo-target/${wasmTarget}/${profileDir}"

        mkdir -p "$out"${lib.optionalString isFrontend "/worker"}
        cp "$artifacts/render_wasm.js" "$out/render-wasm.js"
        cp "$artifacts/render_wasm.wasm" "$out/render-wasm.wasm"

        # Match upstream copy_artifacts(): rename the wasm reference and add
        # a version query for cache busting.
        sed -i "s/render_wasm\.wasm/render-wasm.wasm?version=${version}/g" \
          "$out/render-wasm.js"

        shared="$(find "$PWD/cargo-target/${wasmTarget}" -name render_wasm_shared.js | head -n 1)"
        cp "$shared" "$out/shared.js"

        ${lib.optionalString isFrontend ''
          # Worker bundle, exactly as upstream copy_artifacts() builds it
          # (the exporter imports the ESM module directly instead).
          esbuild "$artifacts/render_wasm.js" \
            --log-level=error \
            --outfile="$out/worker/render.js" \
            --platform=neutral \
            --format=iife \
            --global-name=WasmModule
        ''}

        # Fail loudly instead of shipping an empty/broken artifact.
        test -s "$out/render-wasm.js"
        test -s "$out/render-wasm.wasm"
        test -s "$out/shared.js"

        runHook postInstall
      '';

      meta = {
        description =
          if isFrontend then
            "Penpot WebAssembly canvas renderer (frontend flavor)"
          else
            "Penpot WebAssembly canvas renderer (exporter flavor)";
        homepage = "https://penpot.app";
        license = lib.licenses.mpl20;
        platforms = lib.platforms.linux;
      };
    };
in
let
  frontend = buildRenderWasm "frontend";
in
frontend
// {
  passthru = frontend.passthru or { } // {
    export = buildRenderWasm "export";
  };
}
