{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.jellyfin;
  model = import ./model.nix { inherit config outputs; };
  declarativeConfig = config.host.jellyfinDeclarativeConfig;
  configuredUsers = declarativeConfig.users or [ ];
  passwordSecrets = lib.genAttrs (map (user: user.passwordSecret) configuredUsers) (_: {
    owner = "jellarr";
    group = "jellarr";
    mode = "0400";
  });
  jellarrUsers = map (
    user:
    removeAttrs user [ "passwordSecret" ]
    // {
      passwordFile = config.sops.secrets.${user.passwordSecret}.path;
    }
  ) configuredUsers;
in
{
  config = lib.mkMerge [
    {
      host.jellyfinDeclarativeConfig = lib.mkMerge (
        map (contribution: contribution.config) model.targetedContributions
      );
    }
    (lib.mkIf (cfg != null) {
      sops = {
        secrets = passwordSecrets;
        templates."jellarr.env" = {
          owner = "jellarr";
          group = "jellarr";
          mode = "0400";
          content = ''
            JELLARR_API_KEY=${config.sops.placeholder."jellyfin/apiKey"}
          '';
        };
      };

      services.jellarr = {
        enable = true;
        package = pkgs.callPackage ./packages/jellarr { src = inputs.jellarr; };
        environmentFile = config.sops.templates."jellarr.env".path;
        config = declarativeConfig // {
          version = 1;
          base_url = cfg.localUrl;
          users = jellarrUsers;
        };
      };

      systemd.services.jellarr = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };
    })
  ];
}
