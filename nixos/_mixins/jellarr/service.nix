{
  config,
  lib,
  ...
}:
let
  cfg = config.host.jellarr;
  passwordSecret = user: "jellyfin/users/${lib.toLower user.name}/password";
  configuredUsers = if cfg.enable then config.services.jellarr.config.users else [ ];
  passwordSecrets = lib.genAttrs (map passwordSecret configuredUsers) (_: {
    owner = "jellarr";
    group = "jellarr";
    mode = "0400";
  });
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
      config = {
        version = 1;
        base_url = cfg.target.url;
      };
    };

    systemd.services.jellarr = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
