{
  config,
  fleetInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.network.homeCacheDns;
  lan = config.host.site.lan;
  ingressHost = fleetInventory.webIngress.home.host;
  cache = fleetInventory.webServices.byOwner.${ingressHost}.attic-cache.declaration.public;
  package = pkgs.callPackage ./pkgs/home-cache-dns { };
  configuration = pkgs.writeText "home-cache-dns.json" (
    builtins.toJSON {
      hostname = cache.hostName;
      address = lan.reservations.${cache.splitDnsHost or ingressHost}.address;
      nameserver = lan.gateway.address;
      interfaces = builtins.attrNames config.host.network.interfaces;
    }
  );
in
{
  options.host.network.homeCacheDns.enable =
    lib.mkEnableOption "LAN DNS for the home cache while on the home network";

  config = lib.mkIf cfg.enable {
    environment.etc."home-cache-dns.json".source = configuration;

    # The daemon owns resolver/<hostname> at runtime so it can remove the
    # override when roaming. Do not declare that file through environment.etc.
    launchd.daemons.home-cache-dns = {
      command = lib.escapeShellArgs [
        (lib.getExe package)
        "--config"
        (toString configuration)
      ];
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-darwin/home-cache-dns.log";
        StandardErrorPath = "/var/log/nix-darwin/home-cache-dns.log";
      };
    };
  };
}
