{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.jellarr;
  model = import ./model.nix { inherit config outputs; };
  configuredUsers = model.declarativeConfig.users or [ ];
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
  config = lib.mkIf cfg.enable {
    sops = {
      secrets = passwordSecrets // {
        "jellyfin/apiKey" = { };
      };
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
      package = cfg.package;
      environmentFile = config.sops.templates."jellarr.env".path;
      config = model.declarativeConfig // {
        version = 1;
        base_url = cfg.target.url;
        users = jellarrUsers;
      };
    };

    systemd.services.jellarr = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
