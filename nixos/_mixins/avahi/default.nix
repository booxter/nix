{
  config,
  hostname,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  removePrefix = lib.strings.removePrefix;
  removeSuffix = lib.strings.removeSuffix;
  hostSpecName = removeSuffix "vm" (removePrefix "prox-" (removePrefix "local-" hostname));
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};

  aliasAddress =
    hostSpec.dhcpReservation.ip or hostSpec.lanAddress or hostSpec.ipAddress
      or (throw "host ${hostSpec.name} does not have a stable IPv4 address for mDNS aliases");
  aliases = lib.unique ((hostSpec.localDnsAliases or [ ]) ++ config.host.internalHttps.localAliases);
  hostsFile = pkgs.writeText "avahi-hosts" (
    lib.concatMapStringsSep "\n" (alias: "${aliasAddress} ${alias}.local") aliases + "\n"
  );
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
      addresses = true;
    };
    hostName = removeSuffix "vm" (removePrefix "prox-" hostname);
  };

  environment.etc."avahi/hosts" = lib.mkIf (aliases != [ ]) {
    source = hostsFile;
  };

  systemd.services.avahi-daemon.restartTriggers = lib.mkIf (aliases != [ ]) [ hostsFile ];
}
