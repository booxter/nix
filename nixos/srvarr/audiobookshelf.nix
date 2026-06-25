{
  config,
  hostInventory,
  lib,
  pkgs,
  srvarrPkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  idService = hostInventory.servicesById.id;
  port = 9292;
  stateDir = "${config.host.srvarrPaths.stateDir}/audiobookshelf";
  user = "audiobookshelf";
  audiobookshelfService = hostInventory.servicesById.audiobookshelf;
  oidcClientId = "audiobookshelf";
  oidcIssuerBase = "https://${idService.publicHost}/oauth2/openid/${oidcClientId}";
  oidcSettingsFile = pkgs.writeText "audiobookshelf-oidc-settings.json" (
    builtins.toJSON {
      authActiveAuthMethods = [
        "local"
        "openid"
      ];
      authOpenIDIssuerURL = oidcIssuerBase;
      authOpenIDAuthorizationURL = "https://${idService.publicHost}/ui/oauth2";
      authOpenIDTokenURL = "https://${idService.publicHost}/oauth2/token";
      authOpenIDUserInfoURL = "${oidcIssuerBase}/userinfo";
      authOpenIDJwksURL = "${oidcIssuerBase}/public_key.jwk";
      authOpenIDLogoutURL = null;
      authOpenIDClientID = oidcClientId;
      authOpenIDClientSecret = null;
      authOpenIDTokenSigningAlgorithm = "ES256";
      authOpenIDButtonText = "SSO";
      authOpenIDAutoLaunch = false;
      authOpenIDAutoRegister = true;
      authOpenIDMatchExistingBy = "username";
      authOpenIDMobileRedirectURIs = [ "audiobookshelf://oauth" ];
      authOpenIDGroupClaim = "abs_groups";
      authOpenIDAdvancedPermsClaim = "";
    }
  );
  bootstrapChangedFile = "/run/audiobookshelf-oidc-bootstrap/changed";
  restartIfBootstrapChanged = pkgs.writeShellScript "audiobookshelf-oidc-restart-if-changed" ''
    if [ -e ${lib.escapeShellArg bootstrapChangedFile} ]; then
      exec ${pkgs.systemd}/bin/systemctl try-restart audiobookshelf.service
    fi
  '';
in
{
  sops.secrets = {
    "audiobookshelf/bootstrap/api_token" = {
      mode = "0400";
      restartUnits = [ "audiobookshelf-oidc-bootstrap.service" ];
    };
    "audiobookshelf/oidc/client_secret" = {
      mode = "0400";
      restartUnits = [ "audiobookshelf-oidc-bootstrap.service" ];
    };
  };

  services.audiobookshelf = {
    enable = true;
    dataDir = stateDir;
    group = "media";
    port = port;
    user = user;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  # Upstream assumes dataDir lives under /var/lib; keep only the overrides
  # needed for the absolute state path we use on srvarr.
  systemd.services.audiobookshelf.serviceConfig.WorkingDirectory = lib.mkForce stateDir;

  systemd.services.audiobookshelf-oidc-bootstrap = {
    description = "Configure Audiobookshelf OIDC";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "audiobookshelf.service"
      "sops-install-secrets.service"
    ];
    after = [
      "audiobookshelf.service"
      "sops-install-secrets.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "audiobookshelf-oidc-bootstrap";
      RuntimeDirectoryMode = "0700";
      ExecStart = "${lib.getExe srvarrPkgs.audiobookshelf-oidc-bootstrap} --url http://127.0.0.1:${toString port} --api-token-file ${
        config.sops.secrets."audiobookshelf/bootstrap/api_token".path
      } --client-secret-file ${
        config.sops.secrets."audiobookshelf/oidc/client_secret".path
      } --settings-file ${oidcSettingsFile} --changed-file ${bootstrapChangedFile}";
      ExecStartPost = restartIfBootstrapChanged;
    };
  };

  users.users.${user} = {
    home = lib.mkForce "/var/empty";
    uid = accounts.uids.audiobookshelf;
  };

  host.internalHttps.services.audiobookshelf = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    serverAliases = [ audiobookshelfService.publicHost ];
    mtls.enable = true;
  };
}
