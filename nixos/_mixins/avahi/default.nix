{
  config,
  hostname,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  hostSpecName = hostInventory.nixosConfigNameToSpecName hostname;
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};

  aliasAddress =
    hostSpec.dhcpReservation.ip or hostSpec.lanAddress or hostSpec.ipAddress
      or (throw "host ${hostSpec.name} does not have a stable IPv4 address for mDNS aliases");
  aliases = lib.unique ((hostSpec.localDnsAliases or [ ]) ++ config.host.internalHttps.localAliases);
  aliasNames = builtins.map (alias: "${alias}.local") aliases;
  publishAliases = pkgs.writeShellScript "avahi-publish-aliases" ''
    set -euo pipefail

    pids=()
    cleanup() {
      trap - EXIT
      if [ "''${#pids[@]}" -gt 0 ]; then
        kill "''${pids[@]}" 2>/dev/null || true
      fi
    }
    trap cleanup INT TERM EXIT

    for alias in ${lib.escapeShellArgs aliasNames}; do
      ${config.services.avahi.package}/bin/avahi-publish-address -f -R "$alias" ${lib.escapeShellArg aliasAddress} &
      pids+=("$!")
    done

    wait -n "''${pids[@]}"
  '';
in
{
  services.avahi = {
    enable = true;
    # NixOS uses separate knobs for v4/v6 NSS.
    nssmdns4 = true;
    nssmdns6 = true;
    # Ensure this host publishes its name/address over mDNS.
    publish = {
      enable = true;
      userServices = true;
      addresses = true;
    };
    hostName = hostSpec.name;
  };

  systemd.services.avahi-aliases = lib.mkIf (aliases != [ ]) {
    description = "Avahi mDNS host aliases";
    after = [ "avahi-daemon.service" ];
    requires = [ "avahi-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ publishAliases ];
    serviceConfig = {
      ExecStart = publishAliases;
      Restart = "on-failure";
      RestartSec = "5s";
      User = "avahi";
      Group = "avahi";
    };
  };
}
