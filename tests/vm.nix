# A minimal headless NixOS VM running a full Penpot stack (backend, nginx
# vhost, exporter, MCP, PostgreSQL, Valkey and the mailpit SMTP sink).
#
# Build it with:
#   nix build .#nixosConfigurations.penpot-vm.config.system.build.vm
# and run it headless with:
#   ./result/bin/run-penpot-vm-vm
#
# The guest's port 8080 (the vhost's listen port, matching the public URI)
# is forwarded to the host's port 8080, so once the VM is up you can verify
# the deployment from the host:
#   curl -fsS http://127.0.0.1:8080/readyz     # backend health (via nginx)
#   curl -fsS http://127.0.0.1:8080/          # frontend
#   curl -fsS http://127.0.0.1:8080/js/config.js
# The mailpit SMTP-sink UI is forwarded too: http://localhost:8025
{
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    ./penpot-config.nix
  ];

  networking.hostName = "penpot-vm";

  # Headless: serial console only.
  virtualisation.graphics = false;
  virtualisation.qemu.consoles = [ "ttyS0" ];
  boot.kernelParams = [ "console=ttyS0,115200" ];

  # The Clojure backend plus Chromium-driven exporter need some headroom.
  virtualisation.memorySize = 3072;
  virtualisation.diskSize = 4096;

  # Host and guest ports must match: the vhost listens on the public URI's
  # port (8080) and the served config.js points the app at that URL.
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 8080;
      guest.port = 8080;
    }
    {
      from = "host";
      host.port = 8025;
      guest.port = 8025;
    }
  ];

  system.stateVersion = "25.11";

  # Convenience for poking around over the serial console.
  services.getty.autologinUser = "root";
  users.users.root.initialHashedPassword = "";
}
