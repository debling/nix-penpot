# Penpot MCP server (upstream `mcp/` pnpm workspace).
#
# The esbuild bundle (packages/server/dist/index.js) keeps the node
# dependencies external, so the runtime needs a real node_modules tree.
# We materialize it offline with pnpm's `deploy` from the fetched store.
{
  lib,
  penpot,
  version,
  subSrc,
  stdenv,
  stdenvNoCC,
  runCommand,
  makeWrapper,
  nodejs_24,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
}:
let
  # Only the mcp/ workspace is needed from the Penpot source tree.
  mcpSrc = subSrc penpot [ "mcp" ];

  # 2.18 adds a shared `storeDir: ../.pnpm-store` to the workspace's
  # pnpm-workspace.yaml; our pnpm fetches are per-workspace fixed-output
  # derivations, so strip the line before the fetch (postPatch strips the
  # consumer copy).
  # Named "source": stdenv's unpack of a directory source copies it to a
  # dir named after `stripHash(src)`, and the fetch below relies on
  # sourceRoot = "source/mcp" (matching the raw subSrc trees, which are
  # also named "source" in the store).
  mcpSrcP = runCommand "source" { } ''
    mkdir "$out"
    cp -r "${mcpSrc}"/. "$out"/
    chmod -R u+w "$out"
    find "$out" -name pnpm-workspace.yaml -exec sed -i '/^storeDir:/d' {} +
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "penpot-mcp";
  inherit version;

  src = mcpSrcP;
  # The filtered source tree keeps the upstream `mcp/` directory;
  # the workspace (pnpm-lock.yaml, pnpm-workspace.yaml) lives there.
  sourceRoot = "source/mcp";

  # Fixed-output fetch of the whole pnpm store (fetcherVersion 3 is
  # unsupported for pnpm 11).
  pnpmDeps = fetchPnpmDeps {
    pname = "penpot-mcp";
    inherit (finalAttrs) src sourceRoot;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-99ef/Qk3tx+etEqepQQVqAW3XL7T1Kr6qQJ7Uxf1z0Y=";
  };

  # 2.18's shared pnpm store config would redirect the offline install away
  # from the fetched store.
  postPatch = ''
    find . -name pnpm-workspace.yaml -exec sed -i '/^storeDir:/d' {} +
  '';

  nativeBuildInputs = [
    makeWrapper
    nodejs_24
    pnpm_11
    pnpmConfigHook
  ];

  # Same build as upstream `mcp/scripts/build` (build-types is not part of
  # it; ApiDocs loads the committed data/api_types.yml at runtime).
  buildPhase = ''
    runHook preBuild
    pnpm -r --filter "mcp-server" run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Produce a standalone production runtime for the server. Unlike the
    # upstream dist/ bundle we materialize node_modules now (from the
    # offline store) instead of shipping a `setup` script that would run
    # `pnpm install` on the user's machine. The esbuild bundle keeps the
    # node dependencies external, so they must ship alongside it.
    pnpm --filter mcp-server \
      --config.inject-workspace-packages=true \
      deploy --prod --offline deploy

    mkdir -p $out/lib/penpot-mcp $out/bin
    # dist contains index.js, static/ and data/ (instructions + api types).
    cp -a deploy/dist/. $out/lib/penpot-mcp/
    cp deploy/package.json $out/lib/penpot-mcp/package.json
    cp -a deploy/node_modules $out/lib/penpot-mcp/node_modules

    # The server resolves data/ relative to the working directory, so the
    # wrapper chdirs into the runtime before exec'ing. Defaults to the
    # multi-user docker runtime; override arguments with PENPOT_MCP_ARGS.
    makeWrapper ${lib.getExe nodejs_24} $out/bin/penpot-mcp \
      --chdir $out/lib/penpot-mcp \
      --set-default PENPOT_MCP_SERVER_HOST 127.0.0.1 \
      --add-flags 'index.js' \
      --add-flags ''${PENPOT_MCP_ARGS:---multi-user}

    runHook postInstall
  '';

  passthru = { inherit (finalAttrs) version pnpmDeps; };

  meta = {
    description = "Penpot MCP server (Model Context Protocol integration for Penpot)";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.linux;
    mainProgram = "penpot-mcp";
  };
})
