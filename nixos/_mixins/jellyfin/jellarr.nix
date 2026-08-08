{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = config.services.jellarr;
  package = pkgs.callPackage ./pkgs/jellarr {
    src = inputs.jellarr;
  };
in
{
  imports = [
    inputs.jellarr.nixosModules.default
  ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable;
        message = "services.jellarr requires services.jellyfin.enable.";
      }
    ];

    services.jellarr = {
      package = lib.mkDefault package;
      user = lib.mkDefault jellyfinCfg.user;
      group = lib.mkDefault jellyfinCfg.group;
      environmentFile = config.sops.templates."jellarr.env".path;
    };

    sops.templates."jellarr.env" = {
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      content = ''
        JELLARR_API_KEY=${config.sops.placeholder.${jellyfinCfg.apiKey.sopsKey}}
      '';
    };

    systemd.services.jellarr = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
