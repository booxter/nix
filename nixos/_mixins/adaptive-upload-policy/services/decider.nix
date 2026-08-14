{
  config,
  lib,
  outputs ? {
    nixosConfigurations = { };
  },
  pkgs,
  utils,
  ...
}:
let
  runtime = import ../runtime.nix {
    inherit
      config
      lib
      outputs
      pkgs
      utils
      ;
  };
  inherit (runtime)
    cfg
    command
    commonServiceConfig
    mtls
    stateDir
    ;
in
{
  config.systemd.services.adaptive-upload-policy = lib.mkIf (cfg != null) {
    description = "Decide adaptive upload policy from Jellyfin playback";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ] ++ lib.optionals mtls.enable mtls.dependencyUnits;
    after = [ "network-online.target" ] ++ lib.optionals mtls.enable mtls.dependencyUnits;
    serviceConfig = commonServiceConfig // {
      ExecStart = command "decide";
      ReadWritePaths = [ stateDir ] ++ lib.optional cfg.metrics.enable cfg.metrics.directory;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
