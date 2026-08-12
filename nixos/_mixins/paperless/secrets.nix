{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg passwordSecretName users;
  oidcClient = config.host.sso.oidc.clients.paperless;
  oidcProviderSecret = "__PAPERLESS_OIDC_CLIENT_SECRET__";
  oidcProvidersJson =
    builtins.replaceStrings [ oidcProviderSecret ] [ oidcClient.secret.placeholder ]
      (
        builtins.toJSON {
          openid_connect.APPS = [
            {
              provider_id = "sso";
              name = "SSO";
              client_id = oidcClient.clientId;
              secret = oidcProviderSecret;
              settings = {
                email_authentication = true;
                oauth_pkce_enabled = true;
                server_url = oidcClient.discoveryUrl;
                token_auth_method = "client_secret_basic";
                verified_email = true;
                scope = config.host.sso.oidc.baseScopes ++ [ "groups" ];
              };
            }
          ];
        }
      );
  passwordSecrets = lib.mapAttrs' (
    name: _:
    lib.nameValuePair (passwordSecretName name) {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      restartUnits = [
        "paperless-bootstrap.service"
      ]
      ++ lib.optional (name == model.bootstrapOwner) "paperless-scheduler.service";
    }
  ) users;
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets = passwordSecrets // {
      "paperless/api/token" = {
        owner = "paperless";
        group = "paperless";
        mode = "0400";
        restartUnits = [
          "paperless-bootstrap.service"
          "prometheus-paperless-exporter.service"
        ]
        ++ lib.optionals cfg.gpt.enable [
          "paperless-gpt-configure.service"
          "podman-paperless-gpt.service"
        ];
      };
    };

    sops.templates."paperless-oidc.env" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      content = ''
        PAPERLESS_SOCIALACCOUNT_PROVIDERS='${oidcProvidersJson}'
      '';
      restartUnits = [
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-web.service"
      ];
    };

    sops.templates."paperless-gpt.env" = lib.mkIf cfg.gpt.enable {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        PAPERLESS_API_TOKEN=${config.sops.placeholder."paperless/api/token"}
      '';
      restartUnits = [ "podman-paperless-gpt.service" ];
    };
  };
}
