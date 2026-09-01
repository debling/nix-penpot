# Penpot backend (Clojure API server), packaged as the upstream source
# uberjar. Reproduces `backend/scripts/build`: a non-AOT uberjar executed
# through `clojure.main`, shipped with the log4j2 config and the onboarding
# template files prefetched from penpot/penpot-files.
#
# Output contract:
#   $out/share/penpot-backend/{penpot.jar,log4j2.xml,version.txt,manage.py}
#   $out/share/penpot-backend/builtin-templates/
#   $out/bin/penpot-backend   (java wrapper, cwd = share dir)
#   $out/bin/penpot-manage    (manage.py CLI via python3 + tabulate)
{
  lib,
  stdenv,
  makeWrapper,
  callPackage,
  clojure,
  jdk25_headless,
  babashka,
  imagemagick,
  fontforge,
  woff2,
  fontconfig,
  python3,
  curl,
  cacert,
  git,
  stripJavaArchivesHook,
  penpot,
  version,
  subSrc,
}:

let
  # sfnt2woff/woff2sfnt are not in nixpkgs; see backend-woff-tools.nix.
  woff-tools = callPackage ./backend-woff-tools.nix { };

  # The clojure CLI with a JDK matching the runtime (upstream run.sh flags
  # need >= 24; the nixpkgs default CLI bundles JDK 21).
  clojureJdk25 = clojure.override { jdk = jdk25_headless; };

  magickPolicy = callPackage ./imagemagick-policy.nix { inherit penpot; };

  # The jar build needs `backend/`, its `:local/root` dependency `common/`,
  # and the root `CHANGES.md` (bundled into the jar as changelog.md).
  src = subSrc penpot [
    "backend"
    "common"
    "CHANGES.md"
  ];

  pythonEnv = python3.withPackages (ps: [ ps.tabulate ]);

  # NOTE: upstream's docker image runs Zulu JDK 26 at 2.17.x; any JDK >= 24
  # satisfies the run.sh flags, so the nixpkgs JDK 25 is used here. Revisit
  # when bumping the penpot input.
  # Binaries the backend shells out to at runtime (image/font processing),
  # baked into the wrapper's PATH.
  runtimeBinPath = lib.makeBinPath [
    imagemagick
    fontforge
    woff2
    woff-tools
    fontconfig
  ];

  # Pre-seed all dependency downloads (maven repo + gitlibs checkouts) in a
  # fixed-output derivation so the jar build itself stays fully offline.
  # Three classpaths are warmed: plain root deps (for build.clj's
  # create-basis), the :build alias, and the -T:build tool classpath,
  # version conflicts resolve differently for each, so all three must be
  # pre-fetched.
  mavenDeps = (callPackage ./maven-deps.nix { }).mkMavenDeps {
    pname = "penpot-backend";
    inherit version src;
    workDir = "backend";
    warmAliases = [
      ""
      "-M:build"
      "-T:build"
    ];
    outputHash = "sha256-QV0L59DrWdRDCyV+eVQ0uJwCoe21+8Jcj4LFkwFOvmM=";
  };

  builtinTemplates = stdenv.mkDerivation {
    name = "penpot-backend-builtin-templates";
    src = "${src}/backend";

    nativeBuildInputs = [
      babashka
      curl
    ];

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    # bb.curl shells out to the curl binary, which has no CA bundle in the
    # sandbox.
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    # On a penpot input bump: set to lib.fakeHash, build once, copy the
    # `got:` hash from the failure message.
    outputHash = "sha256-b03i34xCfKHie5AjT7is3o9kqIzcSU/nPl7mV1gu+u0=";
    dontFixup = true;

    dontBuild = true;

    installPhase = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$out/templates"
      bb scripts/prefetch-templates.clj resources/app/onboarding.edn "$out/templates"
    '';
  };
in
stdenv.mkDerivation {
  pname = "penpot-backend";
  inherit version src;

  nativeBuildInputs = [
    clojureJdk25
    git
    makeWrapper
    # Repacks the jar deterministically during fixup (the uber task stamps
    # entries with wall-clock time).
    stripJavaArchivesHook
  ];

  configurePhase = ''
    runHook preConfigure

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ln -s "${mavenDeps}/m2" "$HOME/.m2"
    ln -s "${mavenDeps}/gitlibs" "$HOME/.gitlibs"
    # Keep JVM user.home in sync with HOME so dependency resolution uses
    # the pre-seeded .m2/.gitlibs (see mavenDeps).
    export JDK_JAVA_OPTIONS="-Duser.home=$HOME"

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    (
      cd backend
      mkdir -p target/classes
      echo "$version" > target/classes/version.txt
      cp ../CHANGES.md target/classes/changelog.md
      clojure -T:build jar
    )

    runHook postBuild
  '';

  installPhase = /* sh */ ''
        runHook preInstall

        share="$out/share/penpot-backend"
        mkdir -p "$share" "$out/bin"

        install -Dm644 backend/target/penpot.jar "$share/penpot.jar"
        install -Dm644 backend/resources/log4j2.xml "$share/log4j2.xml"
        cp -r "${builtinTemplates}/templates" "$share/builtin-templates"
        echo "$version" > "$share/version.txt"

        # manage.py hardcodes the prepl endpoint as the argparse default; patch
        # it to honor the PREPL_URI environment variable instead.
        install -Dm755 backend/scripts/manage.py "$share/manage.py"
        substituteInPlace "$share/manage.py" \
          --replace-fail 'import argparse' 'import argparse
    import os' \
          --replace-fail 'default="tcp://localhost:6063"' 'default=os.environ.get("PREPL_URI", "tcp://localhost:6063")'

        # Flags mirror backend/scripts/run.template.sh, except
        # --add-opens=java.base/java.nio (not upstream; needed by
        # yetti/lettuce for direct NIO buffer access on modern JDKs).
        # $JAVA_OPTS and $PENPOT_ENTRYPOINT are embedded verbatim by
        # makeWrapper and expand at runtime, like in the upstream run.sh.
        makeWrapper "${jdk25_headless}/bin/java" "$out/bin/penpot-backend" \
          --chdir "$share" \
          --prefix PATH : "${runtimeBinPath}" \
          --set MAGICK_CONFIGURE_PATH "${magickPolicy}/etc/ImageMagick-7" \
          --set-default PENPOT_ENTRYPOINT app.main \
          --add-flags '-Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager' \
          --add-flags '-Dlog4j2.configurationFile=log4j2.xml' \
          --add-flags '-XX:-OmitStackTraceInFastThrow' \
          --add-flags '--sun-misc-unsafe-memory-access=allow' \
          --add-flags '--enable-native-access=ALL-UNNAMED' \
          --add-flags '--add-opens=java.base/java.nio=ALL-UNNAMED' \
          --add-flags '--enable-preview' \
          --add-flags '$JAVA_OPTS' \
          --add-flags '-jar penpot.jar -m $PENPOT_ENTRYPOINT'

        makeWrapper "${pythonEnv}/bin/python" "$out/bin/penpot-manage" \
          --add-flags "$share/manage.py"

        runHook postInstall
  '';

  passthru = {
    inherit mavenDeps builtinTemplates;
    version = version;
  };

  meta = {
    description = "Penpot backend API server (Clojure uberjar)";
    homepage = "https://penpot.app";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.linux;
    mainProgram = "penpot-backend";
  };
}
