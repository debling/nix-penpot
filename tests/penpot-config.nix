# Common services.penpot configuration shared by the demo VM and the VM test.
#
# NOTE: the public URI must match the URL the stack is actually reached on.
# The demo VM forwards host:8080 -> guest:8080, so browsing
# http://localhost:8080 and calling the API on http://localhost would be a
# cross-origin mismatch (every request would need a failing preflight).
{
  lib,
  pkgs,
  ...
}:
{
  services.penpot = {
    enable = true;
    publicUri = "http://localhost:8080";
    mailpit.enable = true;

    # Registration always creates NON-admin users; admins are granted by
    # email at login time (checked against PENPOT_ADMINS on every request).
    # This demo grants admin to the pre-registered demo account below,
    # replace it with the email you register with, then rebuild and log
    # out/in for it to take effect.
    admins = [ "admin@penpot.local" ];

    # Demo/test-only secret key. Production deployments must supply their
    # own file (e.g. via sops-nix) instead of a store path.
    secretKeyFile = pkgs.writeText "penpot-demo-secret-key" "penpot-demo-secret-key";

    # Demo/test-only passwords exercising the password-credential paths
    # (see the LoadCredential asserts in vm-test.nix). With
    # database.passwordFile set, the local connection uses md5 auth with
    # the provisioned role password instead of the scoped trust rule.
    database.passwordFile = pkgs.writeText "penpot-demo-db-password" "penpot-demo-db-password";
    smtp.username = "penpot-demo";
    smtp.passwordFile = pkgs.writeText "penpot-demo-smtp-password" "penpot-demo-smtp-password";

    # Evaluation defaults mirroring the upstream docker-compose file: skip
    # the email-confirmation roundtrip on registration (the demo SMTP sink
    # still works and is reachable from the host, see below).
    flags = [
      "enable-prepl-server"
      "disable-email-verification"
    ];

    # Keep the backend's JVM footprint predictable in the memory-constrained
    # test/demo VM.
    jvmOpts = [
      "-Xms256m"
      "-Xmx1g"
    ];
  };

  # Demo only: expose the mailpit UI beyond loopback so the host can browse
  # it (http://localhost:8025) and read the emails the instance sends.
  services.mailpit.instances.penpot.listen = "0.0.0.0:8025";

  networking.firewall.allowedTCPPorts = [
    8080
    8025
  ];
}
