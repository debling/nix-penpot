# Penpot frontend: compiles the upstream ClojureScript/JS monorepo into the
# static site served by nginx ($out/dist, mirroring upstream `bundles/frontend`).
#
# Mirrors upstream `frontend/scripts/build`:
#   1. render-wasm artifacts are placed where the wasm cljs glue expects them
#      (instead of building the wasm in-tree).
#   2. MCP plugin is built (its own pnpm workspace).
#   3. Official plugins are built (their own pnpm workspace); the plugins
#      runtime library is built first since the cljs build links it.
#   4. shadow-cljs release build of the `main` and `worker` builds.
#   5. esbuild bundling of the JS libs.
#   6. Asset compilation (styles, sprites, translations, templates, ...).
#   7. Finalization: worker render.js cache-busting, rsync into dist,
#      plugins, version.txt.
{
  lib,
  callPackage,
  penpot,
  version,
  subSrc,
  stdenv,
  stdenvNoCC,
  nodejs_24,
  pnpm_11,
  clojure,
  jdk25_headless,
  git,
  rsync,
  patchelf,
  fetchPnpmDeps,
  pnpmConfigHook,
  # Named renderWasm (not `wasm`) so pkgs.callPackage cannot auto-fill it
  # with nixpkgs' unrelated `pkgs.wasm` (the OCaml interpreter).
  renderWasm ? callPackage ./render-wasm.nix { inherit penpot version; },
}:

let
  src = subSrc penpot [
    "frontend"
    "common"
    "mcp"
    "plugins"
  ];

  # The frontend workspace links `../plugins/libs/plugins-runtime` during
  # install, so plugins/ must be present in its fetch source too.
  frontendSrc = subSrc penpot [
    "frontend"
    "plugins"
  ];
  pluginsSrc = subSrc penpot [ "plugins" ];
  mcpSrc = subSrc penpot [ "mcp" ];
  clojureSrc = subSrc penpot [
    "frontend"
    "common"
  ];

  # One pnpm store per workspace (fetched once, reused for the offline
  # installs in the main build via pnpmConfigHook).
  fetchWorkspaceDeps =
    pname: sourceRoot: wsrc: hash:
    fetchPnpmDeps {
      inherit pname sourceRoot hash;
      pnpm = pnpm_11;
      fetcherVersion = 4;
      src = wsrc;
    };

  frontendPnpmDeps =
    fetchWorkspaceDeps "penpot-frontend-frontend" "source/frontend" frontendSrc
      "sha256-/2VKrkoBfNSQWh9MzN9zY8mZvKIIEtnuSyYxCOsWk94=";
  pluginsPnpmDeps =
    fetchWorkspaceDeps "penpot-frontend-plugins" "source/plugins" pluginsSrc
      "sha256-4q5Mq+TgTU1l5BTdJZJ0F5falMIdQmGpw8t0LTh9g30=";
  mcpPnpmDeps =
    fetchWorkspaceDeps "penpot-frontend-mcp" "source/mcp" mcpSrc
      "sha256-rg8R6uMtqg3uYoqgCCWB9vBkWeDi3fE0djbFfzRU67A=";

  # Upstream's deps.edn passes --sun-misc-unsafe-memory-access=allow, which
  # needs a newer JDK than the one the clojure CLI wrapper ships with.
  clojureJdk25 = clojure.override { jdk = jdk25_headless; };

  # Upstream leaves a few dev deps on "RELEASE"; pin them so both the
  # dependency fetch below and the (offline) shadow-cljs build resolve
  # deterministic, purely local maven versions.
  pinDepsEdn = ''
    sed -i frontend/deps.edn \
      -e 's|binaryage/devtools {:mvn/version "RELEASE"}|binaryage/devtools {:mvn/version "1.0.7"}|' \
      -e 's|org.clojure/tools.namespace {:mvn/version "RELEASE"}|org.clojure/tools.namespace {:mvn/version "1.5.1"}|' \
      -e 's|com.bhauman/rebel-readline {:mvn/version "RELEASE"}|com.bhauman/rebel-readline {:mvn/version "0.1.11"}|'
  '';

  # Maven, gitlibs and classpath caches warming `clojure -P -M:dev:shadow-cljs`.
  # The cpcache (which embeds $HOME paths) lets the main build skip
  # dependency resolution entirely: upstream uses short git shas, whose
  # canonicalization would otherwise need network access.
  mavenDeps = (callPackage ./maven-deps.nix { }).mkMavenDeps {
    pname = "penpot-frontend";
    inherit version;
    src = clojureSrc;
    workDir = "frontend";
    warmAliases = [ "-M:dev:shadow-cljs" ];
    keepCpcache = true;
    scrubM2 = true;
    postPatch = pinDepsEdn;
    outputHash = "sha256-Q7fukU4vPwgGUCQq/PMErzsRzrA6lyFG1fkQENcoRkU=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "penpot-frontend";
  inherit version;
  inherit src;

  nativeBuildInputs = [
    nodejs_24
    pnpm_11
    pnpmConfigHook
    clojureJdk25
    git
    rsync
    patchelf
  ];

  # pnpmConfigHook is invoked once per workspace in preBuild instead
  # (dontPnpmConfigure disables the implicit single-workspace run).
  dontPnpmConfigure = true;

  postPatch = ''
    ${pinDepsEdn}
  '';

  env = {
    NODE_ENV = "production";
    # Baked into the cljs output (app.config/compiled-version-tag).
    VERSION = version;
    # Upstream appends the wall-clock build time (VERSION_TAG =
    # "$VERSION-$BUILD_TS"); a plain version keeps the build deterministic
    # while still busting caches.
    VERSION_TAG = version;
    # _helpers.js embeds these in the bundle when set; pin them for
    # reproducibility (upstream exports the wall clock).
    BUILD_DATE = "Thu Jan 01 00:00:00 UTC 1970";
    BUILD_TS = "0";
  };

  preBuild = ''
    # pnpmConfigHook honors two variables: $pnpmRoot (where the workspace
    # lives; the hook pushd's into it) and $pnpmDeps (the fetched store,
    # visible to the hook via bash dynamic scoping from the local).
    installWorkspace() {
      local pnpmRoot="$1" pnpmDeps="$2"
      pnpmConfigHook
    }

    installWorkspace frontend ${frontendPnpmDeps}
    installWorkspace plugins ${pluginsPnpmDeps}
    installWorkspace mcp ${mcpPnpmDeps}

    # sass-embedded ships a prebuilt dart VM expecting the host loader.
    sassPkg=${
      if stdenvNoCC.hostPlatform.isx86_64 then "sass-embedded-linux-x64" else "sass-embedded-linux-arm64"
    }
    patchelf --set-interpreter "$(cat ${stdenv.cc.bintools}/nix-support/dynamic-linker)" \
      frontend/node_modules/.pnpm/$sassPkg@*/node_modules/$sassPkg/dart-sass/src/dart
  '';

  buildPhase = ''
    runHook preBuild

    # 1. render-wasm artifacts.
    mkdir -p frontend/src/app/render_wasm/api frontend/resources/public/js/worker
    install -m644 ${renderWasm}/render-wasm.js ${renderWasm}/render-wasm.wasm frontend/resources/public/js/
    install -m644 ${renderWasm}/worker/render.js frontend/resources/public/js/worker/render.js
    install -m644 ${renderWasm}/shared.js frontend/src/app/render_wasm/api/shared.js

    # 2. MCP plugin.
    (cd mcp && WS_URI=/mcp/ws pnpm run --filter mcp-plugin build)

    # 3. Official plugins.
    (cd plugins/libs/plugins-runtime && pnpm run build)
    (cd plugins && pnpm run build:plugins)

    # 4. Main cljs build with the pre-seeded clojure caches.
    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME/.clojure"
    export JAVA_TOOL_OPTIONS="-Duser.home=$HOME"
    cp -r ${mavenDeps}/m2 "$HOME/.m2"
    cp -r ${mavenDeps}/gitlibs "$HOME/.gitlibs"
    chmod -R u+w "$HOME/.m2" "$HOME/.gitlibs"
    cp -r ${mavenDeps}/cpcache frontend/.cpcache
    chmod -R u+w frontend/.cpcache
    # Pre-seed the user deps.edn (the CLI would copy its example otherwise)
    # and refresh the cache mtimes so the CLI's `-nt` staleness check does
    # not force a (network) re-resolution.
    echo '{}' > "$HOME/.clojure/deps.edn"
    touch -d '2000-01-01' "$HOME/.clojure/deps.edn"
    touch frontend/.cpcache/*

    (cd frontend && pnpm run build:app:main)
    (cd frontend && pnpm run build:app:libs)
    (cd frontend && pnpm run build:app:assets)

    # 5. Finalize the compiled assets (the dist assembly itself happens in
    # installPhase).
    sed -i "s|\./render.js|./render.js?version=$version|g" frontend/resources/public/js/worker/main*.js

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/dist
    rsync -a frontend/resources/public/ $out/dist/
    rsync -a plugins/dist/apps/ $out/dist/plugins/
    mkdir -p $out/dist/plugins/mcp
    rsync -a mcp/packages/plugin/dist/ $out/dist/plugins/mcp/
    echo "$version" > $out/dist/version.txt
    install -m644 ${penpot}/LICENSE $out/dist/LICENSE

    # The NixOS module re-renders flags into the config template at system
    # build time; upstream also serves it from dist/js/config.js.
    install -m644 ${penpot}/docker/images/files/config.js $out/config.js
    install -m644 ${penpot}/docker/images/files/config.js $out/dist/js/config.js

    runHook postInstall
  '';

  passthru.version = version;

  meta = {
    description = "Penpot frontend static bundle";
    homepage = "https://penpot.app";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.linux;
  };
}
