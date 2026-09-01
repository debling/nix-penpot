# nix-penpot

Run [Penpot](https://penpot.app), the open-source design and prototyping
platform on NixOS. This flake builds every Penpot component from the
upstream source (pinned to a release tag) and ships one NixOS module that
wires the whole stack together: Clojure API backend, static frontend behind
nginx, headless-Chromium exporter, MCP server, PostgreSQL and Valkey,
either provisioned for you or pointed at infrastructure you already run.

## Deploying on NixOS

Add the flake to your configuration:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-penpot.url = "github:debling/nix-penpot";
  };

  outputs = { self, nixpkgs, nix-penpot }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        # Required: the module's package defaults resolve through the overlay
        { nixpkgs.overlays = [ nix-penpot.overlays.default ]; }
        nix-penpot.nixosModules.default
      ];
    };
  };
}
```

Then enable it:

```nix
# configuration.nix
{
  services.penpot = {
    enable = true;
    publicUri = "https://penpot.example.com";
    secretKeyFile = "/etc/penpot-secret-key";
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

That is a complete deployment: PostgreSQL and Valkey are provisioned
locally, the nginx vhost is generated, and the exporter + MCP services
run behind it. Secrets are passed as files through systemd credentials
generate the master key once with:

```bash
openssl rand -base64 64 | tr -d '\n' > /run/secrets/penpot-secret-key
```

Commonly tuned options (all documented inline in
[`modules/penpot.nix`](modules/penpot.nix)):

|Option                          |Default                    |What it does                                               |
|--------------------------------|---------------------------|-----------------------------------------------------------|
|`publicUri`                     |- (required)               |Public URL of the instance                                 |
|`secretKeyFile`                 |- (required)               |Master secret key file                                     |
|`flags`                         |`[ "enable-prepl-server" ]`|Upstream feature flags                                     |
|`database.createLocally`        |`true`                     |Local PostgreSQL, or set `database.uri` for an external one|
|`redis.createLocally`           |`true`                     |Local Valkey, or set `redis.uri`                           |
|`storage.backend`               |`"fs"`                     |`"fs"` or `"s3"` (+ endpoint/bucket/keys)                  |
|`smtp.*` / `mailpit.enable`     |off                        |Outgoing email, or a local throwaway SMTP sink             |
|`exporter.enable` / `mcp.enable`|`true`                     |Toggle the auxiliary services                              |
|`nginx.forceHttps`              |`false`                    |Force HTTPS (configure TLS yourself)                       |

Packages are exposed through an overlay (`pkgs.penpot-backend`,
`pkgs.penpot-frontend`, `pkgs.penpot-exporter`, `pkgs.penpot-mcp`). The
overlay is **required** for the module, its package defaults resolve
through it (see the snippet above); it also lets you override the packages
(per-component `services.penpot.package.*` options exist for that).

## Users and admins

There are no default credentials, create the first user one of two ways.

**Through the UI:** open the app, hit *Register*, fill in email and
password. If email verification is on (default), confirm through your
mail provider, or set `mailpit.enable` for a local sink to read those
emails.

**Through the CLI:** the machine running the backend has `penpot-manage`
on PATH (needs the default `enable-prepl-server` flag). It creates active
accounts directly, no email involved:

```bash
penpot-manage create-profile -n "Jane Doe" -e jane@example.org -p 'secret'
```

**Making a user admin:** registration always creates non-admin users.
List the email in `services.penpot.admins` and rebuild, the right applies
at the next login and is re-checked on every request:

```nix
services.penpot.admins = [ "jane@example.org" ];
```

## Trying it in a VM

Builds a minimal headless NixOS VM with the full stack, without touching
your system:

```bash
nix build .#nixosConfigurations.penpot-vm.config.system.build.vm
./result/bin/run-penpot-vm-vm
```

The VM boots on a serial console and forwards host port 8080 to the
guest's nginx vhost (the public URI's port) and host port 8025 to the
mailpit UI, where emails the instance sends land. Once the backend has
finished booting (a minute or two, it is running from source), check from
the host:

```bash
curl http://127.0.0.1:8080/readyz     # backend health
curl http://127.0.0.1:8080/          # the UI
```

Register a user through the UI to log in (see [Users and
admins](#users-and-admins)). The VM provisions everything locally, it
is a sandbox, safe to throw away. (Needs ~3 GB RAM; KVM speeds it up
if available.)

## Tests and development

```bash
nix flake check --no-build                        # eval everything
nix build .#checks.x86_64-linux.penpot-vm-test    # full end-to-end VM test
nix develop                                       # devshell
```

## Updating Penpot

Bump the `penpot` input (e.g. `nix flake lock --update-input penpot` or pin
a new tag in `flake.nix`). Dependency caches are hash-pinned fixed-output
derivations; on a bump, set their `hash`/`outputHash` to `lib.fakeHash`,
build, and copy the `got:` hash from the failure, the spots are documented
in each file under [`packages/`](packages/).

## License

The Nix code in this repository (flake, module, packages, tests) is
MIT licensed, see [LICENSE](LICENSE). It is provided "AS IS", without
warranty of any kind: if it breaks your instance, eats your data, or
otherwise misbehaves, that is on you. Penpot itself is
[MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0/) (which each package
also records in its `meta.license`), and the rest of the stack
(PostgreSQL, Valkey, Chromium, etc.) ships under its own
licenses. Deploying or redistributing a built instance means complying
with those upstream licenses too.
