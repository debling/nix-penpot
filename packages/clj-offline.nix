# Shared offline Clojure dependency wiring, backed by clj-nix.
#
# `mk-deps-cache` materializes `deps-lock.json` (committed at the repo root)
# purely at eval time — `fetchurl` per Maven artifact, `fetchgit` per git
# dep — so consumer builds resolve fully offline and deterministically, with
# no fixed-output derivation involved.
#
# Consumers: point tools.deps at the cache (same recipe as clj-nix's own
# builder), expand short `:git/sha` pins to full SHAs from the lock, and
# keep `fake-git` (a `git` shim answering rev-parse/tag/merge-base from lock
# metadata) on PATH for any stray git invocation.
{
  mk-deps-cache,
  fake-git,
  clj-builder,
}:
let
  cache = mk-deps-cache {
    lockfile = ../deps-lock.json;
  };
in
{
  inherit cache fake-git clj-builder;

  # Shell fragment for consumer preBuild/configure phases. Must run in the
  # project root (the directory `deps-lock.json` is copied into), before any
  # `clojure` invocation. Uses a writable HOME with symlinks into the
  # read-only cache (pnpm and friends need a writable HOME; clojure
  # resolution follows the symlinks).
  setup = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ln -sfn "${cache}/.m2" "$HOME/.m2"
    ln -sfn "${cache}/.gitlibs" "$HOME/.gitlibs"
    ln -sfn "${cache}/.clojure" "$HOME/.clojure"
    # The JVM resolves user.home from /etc/passwd rather than $HOME; force
    # it so tools.deps resolves from the cache instead of attempting
    # network downloads.
    export JAVA_TOOL_OPTIONS="-Duser.home=$HOME"
    export CLJ_CONFIG="$HOME/.clojure"
    export CLJ_CACHE="$TMPDIR/cp_cache"
    export GITLIBS="$HOME/.gitlibs"
    cp "${../deps-lock.json}" deps-lock.json
    clj-builder patch-git-sha "$(pwd)"
  '';
}
