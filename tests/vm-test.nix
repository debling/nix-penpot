{
  lib,
  self,
  ...
}:
{
  name = "penpot";
  meta.maintainers = with lib.maintainers; [ ];

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        { nixpkgs.overlays = [ self.overlays.default ]; }
        self.nixosModules.default
        ./penpot-config.nix
      ];

      # Room for the backend JVM, the exporter's Chromium pool and
      # PostgreSQL during boot.
      virtualisation.memorySize = 3072;
      virtualisation.diskSize = 4096;
    };

  testScript = ''
    start_all()

    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("redis-penpot.service")
    machine.wait_for_unit("mailpit-penpot.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("penpot-backend.service")

    def http(url, extra="", fail=True):
        """Fetch url with curl and return the response body or headers.

        fail=False keeps going on HTTP error statuses, for endpoints that
        answer with a useful body on them (e.g. the MCP 406)."""
        flag = "-f " if fail else ""
        return machine.succeed("curl -sS " + flag + extra + " " + url)

    def http_code(url, extra=""):
        return machine.succeed(
            f"curl -sS -o /dev/null -w '%{{http_code}}' {extra} {url}"
        ).strip()

    mcp_init = (
        "-X POST -H 'Content-Type: application/json' "
        "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}'"
    )

    # The backend is a source-run Clojure uberjar: give it a generous window
    # to reach the readyz endpoint (which also exercises the database).
    machine.wait_until_succeeds(
        "curl -fsS http://localhost:8080/readyz -o /tmp/readyz && grep -q OK /tmp/readyz",
        timeout=900,
    )

    # Provisioning and secret handling.
    machine.succeed("systemctl is-active penpot-db-setup.service")
    dbowner = machine.succeed(
        "su postgres -c \"psql -tAc \\\"SELECT pg_get_userbyid(datdba)"
        " FROM pg_database WHERE datname='penpot'\\\"\""
    )
    assert "penpot" in dbowner
    machine.succeed("test -d /var/lib/penpot/assets")

    # Frontend static site and rendered configuration.
    assert "<!doctype html" in http("http://localhost:8080/").lower()
    config_js = http("http://localhost:8080/js/config.js")
    for needle in ("penpotPublicURI", "disable-secure-session-cookies", "enable-smtp"):
        assert needle in config_js
    assert "no-store" in http("http://localhost:8080/js/config.js", "-I").lower()
    assert len(http("http://localhost:8080/js/worker/main.js")) > 0
    assert "max-age=604800" in http("http://localhost:8080/js/worker/main.js", "-I")

    # Exporter and MCP entry points.
    machine.wait_for_unit("penpot-exporter.service")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:6061/readyz -o /tmp/exporter-readyz"
        " && grep -q OK /tmp/exporter-readyz",
        timeout=120,
    )
    machine.wait_for_unit("penpot-mcp.service")
    machine.wait_for_open_port(4401)
    # In multi-user mode a tokenless initialize is answered with a JSON-RPC
    # error (HTTP 406); any well-formed JSON-RPC response proves the server
    # is serving the MCP protocol.
    assert "jsonrpc" in http("http://127.0.0.1:4401/mcp", mcp_init, fail=False)

    # The vhost routes /api/export to the exporter: the status code via the
    # vhost equals the one from hitting the exporter directly (the exporter
    # answers unauthenticated GETs with its own validation error), proving
    # the proxy hop without hardcoding a status.
    assert http_code("http://localhost:8080/api/export/readyz") == http_code(
        "http://127.0.0.1:6061/api/export/readyz"
    )
    assert "jsonrpc" in http("http://localhost:8080/mcp/stream", mcp_init, fail=False)

    # Administrative CLI bootstrap path (no email roundtrip): the
    # penpot-manage tool ships on the machine PATH and talks to the backend
    # prepl server; profiles created through it are active immediately.
    machine.succeed(
        "penpot-manage create-profile -n 'CLI Admin'"
        " -e cli@penpot.local -p cli-password-123"
    )
    cli_login = http(
        "http://localhost:8080/api/rpc/command/login-with-password",
        "-X POST -H 'Content-Type: application/transit+json' "
        + "-d '[\"^ \",\"~:email\",\"cli@penpot.local\","
        + "\"~:password\",\"cli-password-123\"]'",
        fail=False,
    )
    assert "cli@penpot.local" in cli_login
    assert '"~:is-admin",false' in cli_login

    # Real API roundtrip (nginx -> backend -> database): an unknown user
    # login gets the backend's own validation error back.
    assert "wrong-credentials" in http(
        "http://localhost:8080/api/rpc/command/login-with-password",
        "-X POST -H 'Content-Type: application/transit+json' "
        + "-d '[\"^ \",\"~:email\",\"probe@example.org\","
        + "\"~:password\",\"wrong-password-123\"]'",
        fail=False,
    )

    # Websocket proxying path answers (backend not fully upgraded without a
    # client, but the vhost must not 404 on it).
    assert http_code(
        "http://localhost:8080/ws/notifications",
        "-H 'Upgrade: websocket' -H 'Connection: Upgrade'",
    ) in ("426", "400", "101")

    # SMTP sink: deliver a mail through mailpit via curl's SMTP client and
    # read it back through the mailpit API.
    machine.succeed(
        "printf 'Subject: penpot-test\\r\\nFrom: test@example.org\\r\\nTo:"
        " test@example.org\\r\\n\\r\\nhello from the test\\r\\n'"
        " | curl -sS smtp://127.0.0.1:1025"
        " --mail-from test@example.org --mail-rcpt test@example.org -T -"
    )
    machine.wait_until_succeeds(
        "curl -fsS 'http://127.0.0.1:8025/api/v1/messages' -o /tmp/mailpit"
        " && grep -q penpot-test /tmp/mailpit",
        timeout=60,
    )

    # Restart semantics: the backend must come back to a healthy state
    # after a restart.
    machine.succeed("systemctl restart penpot-backend.service")
    machine.wait_until_succeeds(
        "curl -fsS http://localhost:8080/readyz -o /tmp/readyz2 && grep -q OK /tmp/readyz2",
        timeout=900,
    )
  '';
}
