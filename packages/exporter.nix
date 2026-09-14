# Penpot exporter: the ClojureScript -> Node.js headless export service
# (renders designs via Playwright/Chromium, talks to redis + the Penpot
# internal API).
#
# Upstream builds this with a pnpm workspace + shadow-cljs and ships the
# `target/` dir of exporter/scripts/build as the runtime bundle. This package
# reproduces that bundle with everything materialized offline: node_modules
# and maven/git deps come from fixed-output derivations, and chromium comes
# from nixpkgs instead of `playwright install`. (The render-wasm based
# exporter rendering postdates the 2.17.x line this package tracks, so the
# wasm artifacts are not consumed here.)
{
  lib,
  stdenv,
  callPackage,
  penpot,
  version,
  subSrc,
  nodejs_24,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  git,
  clojure,
  jdk25_headless,
  chromium,
  makeWrapper,
  imagemagick,
  poppler-utils,
  potrace,
  netpbm,
  makeFontsConf,
  noto-fonts-color-emoji,
  unifont,
  liberation_ttf,
  freefont_ttf,
  ipafont,
  wqy_zenhei,
  tlwg,
}:

let
  # The exporter workspace plus the `common` cljs sources it compiles in
  # (exporter/deps.edn and shadow-cljs.edn reference ../common).
  src = subSrc penpot [
    "exporter"
    "common"
  ];

  # exporter/deps.edn's :shadow-cljs alias passes
  # `--sun-misc-unsafe-memory-access=allow` to the JVM; that option needs
  # JDK >= 23 while nixpkgs' default clojure bundles JDK 21.
  clojureJdk25 = clojure.override { jdk = jdk25_headless; };

  # npm dependencies of the exporter workspace, fetched once into a pnpm
  # store in a fixed-output derivation and materialized offline in the main
  # build via pnpmConfigHook. Lifecycle scripts are skipped: nothing in this
  # dependency set needs them for runtime (playwright's postinstall is
  # informational only), and the playwright browser download is replaced by
  # the browsers dir below.
  exporterSrc = subSrc penpot [ "exporter" ];

  pnpmDeps = fetchPnpmDeps {
    pname = "penpot-exporter";
    inherit version;
    src = exporterSrc;
    sourceRoot = "source/exporter";
    pnpm = pnpm_11;
    # fetcherVersion 4 is required for pnpm 11 (older fetchers are rejected).
    fetcherVersion = 4;
    hash = "sha256-vDZfXXzx4SDhSBdEFq/fQ1WJ3pleFz3QQIU8cSQ53rs=";
  };

  # Maven + tools.deps git dependencies (exporter/deps.edn pulls in
  # ../common, whose deps.edn has a git dependency), fetched once in a
  # fixed-output derivation.
  mavenDeps = (callPackage ./maven-deps.nix { }).mkMavenDeps {
    pname = "penpot-exporter";
    inherit version;
    src = subSrc penpot [
      "exporter"
      "common"
    ];
    workDir = "exporter";
    warmAliases = [ "-M:dev" ];
    outputHash = "sha256-0WBDh+leRpDyQtdtrQ2tDs5Kbn83ENurHKGXZqKWtZI=";
  };

  magickPolicy = callPackage ./imagemagick-policy.nix { inherit penpot; };

  # Fonts matching the upstream exporter image (docker/Dockerfile.exporter):
  # emoji, bitmap fallback (covers the cyrillic/scalable X fonts), latin,
  # gothic, Thai (tlwg) and CJK coverage.
  fontsConf = makeFontsConf {
    fontDirectories = [
      noto-fonts-color-emoji
      unifont
      liberation_ttf
      freefont_ttf
      ipafont
      wqy_zenhei
      tlwg
    ];
  };

  # Executable path layouts that playwright-core resolves below
  # $PLAYWRIGHT_BROWSERS_PATH (see its registry: EXECUTABLE_PATHS differ
  # between linux-x64 and linux-arm64). NOTE: these paths are
  # registry-version-dependent; re-verify against the vendored
  # playwright-core when the lockfile bumps playwright.
  # The headless-shell slot is served by the full chromium build (nixpkgs
  # does not package the separate headless shell).
  chromeDir = if stdenv.hostPlatform.isx86_64 then "chrome-linux64" else "chrome-linux";
  headlessShellDir =
    if stdenv.hostPlatform.isx86_64 then "chrome-headless-shell-linux64" else "chrome-linux";
  headlessShellBin =
    if stdenv.hostPlatform.isx86_64 then "chrome-headless-shell" else "headless_shell";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "penpot-exporter";
  inherit version;

  inherit src;

  nativeBuildInputs = [
    clojureJdk25
    git
    makeWrapper
    nodejs_24
    pnpm_11
    pnpmConfigHook
  ];

  env.NODE_ENV = "production";

  inherit pnpmDeps;

  dontConfigure = true;
  # pnpmConfigHook is invoked manually inside installPhase (configure is
  # disabled), after cd'ing into the exporter workspace.
  dontPnpmConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    cd exporter

    # Materialize node_modules offline from the pre-fetched pnpm store.
    pnpmConfigHook

    # Offline clojure dependency caches for the shadow-cljs release build.
    export HOME=$TMPDIR/home
    mkdir -p $HOME
    cp -a ${mavenDeps}/m2 $HOME/.m2
    cp -a ${mavenDeps}/gitlibs $HOME/.gitlibs
    # The JVM resolves user.home from /etc/passwd rather than $HOME; force it
    # so tools.deps resolves from the pre-seeded .m2/.gitlibs instead of
    # attempting network downloads.
    export JAVA_TOOL_OPTIONS="-Duser.home=$HOME"
    export GITLIBS=$HOME/.gitlibs

    clojure -M:dev:shadow-cljs release main

    # The compiled app.js carries a literal %version% placeholder
    # (upstream exporter/scripts/build substitutes it the same way).
    sed -i "s/%version%/${finalAttrs.version}/g" target/app.js

    # Assemble the runtime dir (the equivalent of upstream's target/).
    mkdir -p $out/lib/penpot-exporter
    cp target/app.js target/app.js.map $out/lib/penpot-exporter/
    cp package.json pnpm-lock.yaml $out/lib/penpot-exporter/
    # Upstream ships pnpm-workspace.yaml emptied out; keep the same.
    touch $out/lib/penpot-exporter/pnpm-workspace.yaml
    cp -a --preserve=links node_modules $out/lib/penpot-exporter/node_modules

    # Pre-materialized playwright browser dir: playwright-core resolves
    # $PLAYWRIGHT_BROWSERS_PATH/chromium-<rev>/... from its own
    # browsers.json, so derive the revision from the exporter's tree and
    # point both chromium flavors at the nixpkgs build.
    pwRevision=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).browsers.find(b => b.name === 'chromium').revision" \
      node_modules/.pnpm/playwright-core@*/node_modules/playwright-core/browsers.json)
    browsers=$out/lib/penpot-exporter-browsers
    mkdir -p $browsers/chromium-$pwRevision/${chromeDir}
    ln -s ${chromium}/bin/chromium $browsers/chromium-$pwRevision/${chromeDir}/chrome
    mkdir -p $browsers/chromium_headless_shell-$pwRevision/${headlessShellDir}
    ln -s ${chromium}/bin/chromium \
      $browsers/chromium_headless_shell-$pwRevision/${headlessShellDir}/${headlessShellBin}

    mkdir -p $out/bin
    makeWrapper ${nodejs_24}/bin/node $out/bin/penpot-exporter \
      --add-flags "$out/lib/penpot-exporter/app.js" \
      --chdir $out/lib/penpot-exporter \
      --prefix PATH : ${
        lib.makeBinPath [
          imagemagick
          poppler-utils
          potrace
          netpbm
          nodejs_24
        ]
      } \
      --set NODE_ENV production \
      --set MAGICK_CONFIGURE_PATH "${magickPolicy}/etc/ImageMagick-7" \
      --set FONTCONFIG_FILE ${fontsConf} \
      --set PLAYWRIGHT_BROWSERS_PATH $out/lib/penpot-exporter-browsers

    runHook postInstall
  '';

  passthru.version = finalAttrs.version;

  meta = {
    description = "Penpot exporter service (headless design export via Chromium)";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.linux;
    mainProgram = "penpot-exporter";
  };
})
