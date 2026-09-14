# Shared fixed-output derivation for pre-seeding clojure tools.deps
# dependency caches (m2 + gitlibs, optionally the project cpcache) so the
# actual builds run fully offline. This is the "double invocation" pattern
# from the nixpkgs maven docs, adapted to tools.deps: the resolver is
# `clojure -P` (driven by deps.edn, which can also pull git dependencies
# into gitlibs, something maven itself cannot express), the consumers are
# clojure/shadow-cljs builds rather than `mvn package`.
{
  lib,
  stdenvNoCC,
  clojure,
  jdk25_headless,
  git,
  cacert,
}:
{
  mkMavenDeps =
    {
      pname,
      version,
      src,
      # Subdirectory of `src` holding deps.edn ("" for the root).
      workDir,
      # Classpath computations to pre-warm, one `clojure -P` per entry,
      # e.g. [ "" "-M:build" "-T:build" ] or [ "-M:dev:shadow-cljs" ].
      warmAliases,
      outputHash,
      # Copy the project cpcache (tools.deps writes it into the working
      # directory, not HOME) so the main build can skip resolution entirely.
      keepCpcache ? false,
      # Extra source patching applied before resolution (e.g. pinning
      # "RELEASE" deps in deps.edn).
      postPatch ? "",
    }:
    stdenvNoCC.mkDerivation {
      name = "${pname}-maven-deps";
      inherit version src;

      # The JVM options our consumers run with need JDK >= 24, and tools.deps
      # must resolve against the same JDK the build uses.
      nativeBuildInputs = [
        (clojure.override { jdk = jdk25_headless; })
        git
      ];

      impureEnvVars = lib.fetchers.proxyImpureEnvVars;

      # curl/git find no CA bundle inside the sandbox; point them at the
      # store's trust store.
      SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";

      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
      # On a penpot input bump: set to lib.fakeHash, build once, copy the
      # `got:` hash from the failure message.
      inherit outputHash;

      dontConfigure = true;
      dontBuild = true;
      # fixup would patch shebangs inside the caches, embedding store paths
      # (which fixed-output outputs must not reference).
      dontFixup = true;

      inherit postPatch;

      installPhase = ''
        runHook preInstall

        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        # The JVM derives user.home from the sandbox passwd entry, not $HOME;
        # force it so tools.deps downloads land in the m2 dir we install.
        export JDK_JAVA_OPTIONS="-Duser.home=$HOME"

        ${lib.concatMapStrings (alias: ''
          (cd ${workDir} && clojure -P ${alias})
        '') warmAliases}

        # Delete Maven resolver bookkeeping unconditionally so the
        # fixed-output hash is stable: these files record wall-clock fetch
        # behavior (resolver-status.properties carries
        # `.lastUpdated=<epoch-ms>` timestamps, `*.lastUpdated` markers
        # record failed lookups, `maven-metadata*` tracks mutable version
        # listings, and `_remote.repositories` records which remote each
        # artifact came from). Offline reuse only needs the real artifacts
        # (`*.jar`, `*.pom`), which are kept verbatim.
        find "$HOME/.m2" \
          \( -name '_remote.repositories' \
          -o -name '_maven.repositories' \
          -o -name 'resolver-status.properties' \
          -o -name '*.lastUpdated' \
          -o -name 'maven-metadata*' \) -type f -delete

        # Uninstall gitlibs content that breaks fixed-output hashing:
        # worktree admin files embed mtimes/absolute builder paths, sample
        # hooks embed nixpkgs-git store shebangs (forbidden references in a
        # FOD), and sha resolution reads checkouts as plain files.
        find "$HOME/.gitlibs/_repos" -type d -name worktrees -exec rm -rf {} +
        find "$HOME/.gitlibs/_repos" -type d -name hooks -exec rm -rf {} +
        find "$HOME/.gitlibs/libs" -name '.git' -type f -delete

        # Canonicalize git object stores so the fixed-output hash is stable
        # across fetches. The server generates a fresh pack per fetch
        # (different deltas/object order), and plain `git repack` reuses
        # incoming deltas, so received packs flow through byte-identically
        # into the output. A full single-threaded re-deltification
        # (`-f`, fixed window/depth/threads) is a pure function of the
        # object set instead. FETCH_HEAD/logs/commit-graphs/server-info are
        # fetch-session state that offline resolution never reads.
        # packed-refs is pruned to tags: coords only reference :git/tag or
        # :git/sha, while branches/pulls move upstream and would drift the
        # hash on every upstream push.
        for repo in "$HOME"/.gitlibs/_repos/*/*/*/*/; do
          [ -d "$repo/objects" ] || continue
          # .keep files protect packs from consolidation; remove first.
          rm -f "$repo"/objects/pack/*.keep
          # repack.updateServerInfo=false: repack would otherwise write
          # info/refs + objects/info/packs (dumb-HTTP server state listing
          # every branch/pull — same drift as packed-refs, and never read
          # offline). Deleted defensively below as well.
          git --git-dir="$repo" -c pack.threads=1 -c repack.updateServerInfo=false \
            repack -a -d -f --window=50 --depth=50 || exit 1
          rm -rf "$repo/FETCH_HEAD" "$repo/logs" "$repo/info/refs" \
            "$repo/objects/info/packs" \
            "$repo/objects/info/commit-graph" \
            "$repo/objects/info/commit-graphs" \
            "$repo/objects/info/commit-graphs-v1"
          if [ -f "$repo/packed-refs" ]; then
            awk 'BEGIN{keep=0} /^#/{print; next} / refs\/tags\//{print; keep=1; next} /^\^/{if(keep)print; keep=0; next} {keep=0}' \
              "$repo/packed-refs" > "$repo/packed-refs.tmp" || exit 1
            mv "$repo/packed-refs.tmp" "$repo/packed-refs"
          fi
        done

        mkdir -p "$out"
        mv "$HOME/.m2" "$out/m2"
        mv "$HOME/.gitlibs" "$out/gitlibs"
        ${if keepCpcache then ''mv "${workDir}/.cpcache" "$out/cpcache"'' else ""}
        # NOTE: when keepCpcache is false, $HOME/.clojure (cpcache) is
        # deliberately not installed either: the cached classpaths embed the
        # builder's $HOME, so they are invalid in the downstream build.
        # Offline resolution from m2/gitlibs suffices.
        #
        # When keepCpcache is TRUE, the shipped classpaths embed absolute
        # /build/home paths. That only replays because the consumer
        # recreates $HOME = /build/home and materializes m2/gitlibs there
        # (see frontend.nix preBuild), it depends on Nix's default build
        # directory.

        runHook postInstall
      '';
    };
}
