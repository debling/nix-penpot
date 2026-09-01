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
  makeWrapper,
  nodejs_24,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
}:
let
  # Only the mcp/ workspace is needed from the Penpot source tree.
  mcpSrc = subSrc penpot [ "mcp" ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "penpot-mcp";
  inherit version;

  src = mcpSrc;
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
    hash = "sha256-rg8R6uMtqg3uYoqgCCWB9vBkWeDi3fE0djbFfzRU67A=";
  };

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
