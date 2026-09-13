{
  description = "Nix packages and NixOS module for self-hosting Penpot";

  nixConfig = {
    extra-substituters = [ "https://nix-penpot.cachix.org" ];
    extra-trusted-public-keys = [ "nix-penpot.cachix.org-1:cbXoCSnLa6QmBex5EYzUSsswqSZA6RvJWl0dR+WgOns=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    penpot.url = "github:penpot/penpot/2.17.2";
    penpot.flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      penpot,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
        };

      penpotVersion = self.lib.mkPenpotVersion penpot;
    in
    {
      lib = {
        mkPenpotVersion =
          src:
          let
            pkg = builtins.readFile (src + "/package.json");
            pkgVersion = builtins.match ".*\"version\": \"([^\"]+)\".*" pkg;
          in
          if pkgVersion != null then
            builtins.head pkgVersion
          else if src ? shortRev then
            src.shortRev
          else
            "dev";

        # Restrict a source tree to a set of top-level paths (directories or
        # files). `paths` entries are matched against the path relative to
        # `src`, so "backend" keeps "backend" itself and everything below it.
        #
        # Type: Path -> [String] -> Path
        subSrc =
          src: paths:
          nixpkgs.lib.cleanSourceWith {
            src = nixpkgs.lib.cleanSource src;
            filter =
              path: _type:
              let
                rel = nixpkgs.lib.removePrefix "${toString src}/" (toString path);
              in
              rel == "" || nixpkgs.lib.any (p: rel == p || nixpkgs.lib.hasPrefix "${p}/" rel) paths;
          };
      };

      overlays.default = final: _prev: {
        penpot-backend = self.packages.${final.stdenv.hostPlatform.system}.penpot-backend;
        penpot-frontend = self.packages.${final.stdenv.hostPlatform.system}.penpot-frontend;
        penpot-exporter = self.packages.${final.stdenv.hostPlatform.system}.penpot-exporter;
        penpot-mcp = self.packages.${final.stdenv.hostPlatform.system}.penpot-mcp;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          callPackage = pkgs.callPackage;
          penpotRenderWasm = callPackage ./packages/render-wasm.nix {
            inherit penpot;
            version = penpotVersion;
          };
        in
        {
          penpot-backend = callPackage ./packages/backend.nix {
            inherit penpot;
            version = penpotVersion;
            inherit (self.lib) subSrc;
          };
          penpot-render-wasm = penpotRenderWasm;
          # Exposed separately so CI/flake-check keeps building the export
          # flavor (nothing consumes it on the 2.17.x line).
          penpot-render-wasm-export = penpotRenderWasm.passthru.export;
          penpot-frontend = callPackage ./packages/frontend.nix {
            inherit penpot;
            version = penpotVersion;
            inherit (self.lib) subSrc;
          };
          penpot-exporter = callPackage ./packages/exporter.nix {
            inherit penpot;
            version = penpotVersion;
            inherit (self.lib) subSrc;
          };
          penpot-mcp = callPackage ./packages/mcp.nix {
            inherit penpot;
            version = penpotVersion;
            inherit (self.lib) subSrc;
          };
          default = self.packages.${system}.penpot-backend;
        }
      );

      nixosModules = {
        default = self.nixosModules.penpot;
        penpot = import ./modules/penpot.nix;
      };

      nixosConfigurations.penpot-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          { nixpkgs.overlays = [ self.overlays.default ]; }
          self.nixosModules.default
          ./tests/vm.nix
        ];
      };

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        { }
        # The VM test only runs on x86_64-linux (it needs the same-system
        # qemu). The test node injects the overlay via nixpkgs.overlays.
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # Full end-to-end VM test of the module (boots PostgreSQL, Valkey,
          # backend, nginx, exporter and MCP, then probes every endpoint).
          penpot-vm-test = pkgs.testers.nixosTest (
            import ./tests/vm-test.nix {
              inherit (pkgs) lib;
              inherit self;
            }
          );
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
