{
  config,
  hostname,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.networking;
  hostSpec = hostInventory.darwinHosts.${hostname} or { };
in
{
  options.host.networking = {
    enable = lib.mkEnableOption "managed Darwin networking settings";

    mainInterface = lib.mkOption {
      type = lib.types.str;
      default = hostSpec.mainInterface or "en0";
      example = "en0";
      description = "Primary network interface for host-local networking features.";
    };

    knownNetworkServices = lib.mkOption {
      type = with lib.types; listOf str;
      default =
        lib.optionals (!config.host.isLaptop) [
          "Ethernet"
        ]
        ++ [
          "Wi-Fi"
        ];
      description = "Network service names managed by nix-darwin.";
    };
  };

  config = lib.mkMerge [
    {
      host.networking.enable = lib.mkDefault (!config.host.isWork);
    }
    (lib.mkIf cfg.enable {
      networking = {
        knownNetworkServices = cfg.knownNetworkServices;
        computerName = hostname;
        dhcpClientId = hostname;
      };

      system.defaults.smb = {
        NetBIOSName = hostname;
        ServerDescription = hostname;
      };
    })
  ];
}
