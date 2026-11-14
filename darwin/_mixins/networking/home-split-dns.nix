{
  config,
  fleetInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.network.homeSplitDns;
  lan = config.host.site.lan;
  publicServices = builtins.filter (
    entry:
    entry.value.public != null && builtins.hasAttr entry.value.public.splitDnsHost lan.reservations
  ) fleetInventory.webServices.contributions;
  package = pkgs.callPackage ./pkgs/home-split-dns { };
  configuration = pkgs.writeText "home-split-dns.json" (
    builtins.toJSON {
      services = map (entry: {
        hostname = entry.value.public.hostName;
        address = lan.reservations.${entry.value.public.splitDnsHost}.address;
      }) publicServices;
      nameserver = lan.gateway.address;
      interfaces = builtins.attrNames config.host.network.interfaces;
    }
  );
in
{
  options.host.network.homeSplitDns.enable =
    lib.mkEnableOption "LAN DNS for public home services while on the home network";

  config = lib.mkIf cfg.enable {
    environment.etc."home-split-dns.json".source = configuration;

    # The daemon owns resolver/<hostname> at runtime so it can remove the
    # override when roaming. Do not declare that file through environment.etc.
    launchd.daemons.home-split-dns = {
      command = lib.escapeShellArgs [
        (lib.getExe package)
        "--config"
        (toString configuration)
      ];
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-darwin/home-split-dns.log";
        StandardErrorPath = "/var/log/nix-darwin/home-split-dns.log";
      };
    };
  };
}
