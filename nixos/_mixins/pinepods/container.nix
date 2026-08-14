{
  config,
  lib,
  pkgs,
  storageIdentities,
  storageModel,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      pkgs
      storageModel
      ;
  };
  inherit (model)
    cfg
    cachePort
    databaseName
    downloadsDir
    image
    imageFile
    oidcClient
    port
    storageGroup
    user
    ;
  complete =
    model.bootstrapReady && downloadsDir != null && storageGroup != null && oidcClient != null;
  dependencies = [
    "network-online.target"
    "pinepods-postgresql-password.service"
    "pinepods-valkey.service"
    "sops-install-secrets.service"
  ];
in
{
  config = lib.mkIf (cfg != null && complete) {
    sops.templates."pinepods.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        DB_PASSWORD=${config.sops.placeholder."pinepods/postgresql/password"}
        VALKEY_PASSWORD=${config.sops.placeholder."pinepods/valkey/password"}
        OIDC_CLIENT_SECRET=${oidcClient.secret.placeholder}
      '';
      restartUnits = [ "podman-pinepods.service" ];
    };

    virtualisation = {
      podman.extraPackages = [ pkgs.slirp4netns ];
      oci-containers = {
        backend = "podman";
        containers.pinepods = {
          inherit image imageFile;
          pull = "never";
          environment = {
            DB_TYPE = "postgresql";
            DB_HOST = "10.0.2.2";
            DB_PORT = "5432";
            DB_USER = user;
            DB_NAME = databaseName;
            VALKEY_HOST = "10.0.2.2";
            VALKEY_PORT = toString cachePort;
            HOSTNAME = model.service.public.url;
            PINEPODS_PORT = "443";
            PROXY_PROTOCOL = "https";
            REVERSE_PROXY = "False";
            SEARCH_API_URL = "https://search.pinepods.online/api/search";
            PEOPLE_API_URL = "https://people.pinepods.online";
            DEBUG_MODE = "true";
            DEFAULT_LANGUAGE = "en";
            TZ = config.host.site.timeZone;
            PUID = toString storageIdentities.users.${user}.uid;
            PGID = toString config.users.groups.${storageGroup}.gid;

            # Native and gPodder-compatible clients authenticate with a
            # username and password even though browsers normally use SSO.
            OIDC_DISABLE_STANDARD_LOGIN = "false";
            OIDC_PROVIDER_NAME = "SSO";
            OIDC_CLIENT_ID = oidcClient.clientId;
            OIDC_AUTHORIZATION_URL = oidcClient.authorizationUrl;
            OIDC_TOKEN_URL = oidcClient.tokenUrl;
            OIDC_USER_INFO_URL = oidcClient.userinfoUrl;
            OIDC_BUTTON_TEXT = "Login with SSO";
            OIDC_SCOPE = lib.concatStringsSep " " (model.oidcScopes ++ [ "pinepods_roles" ]);
            OIDC_BUTTON_COLOR = "#111827";
            OIDC_BUTTON_TEXT_COLOR = "#ffffff";
            OIDC_NAME_CLAIM = "name";
            OIDC_EMAIL_CLAIM = "email";
            OIDC_USERNAME_CLAIM = "preferred_username";
            OIDC_ROLES_CLAIM = "pinepods_roles";
            OIDC_USER_ROLE = "user";
            OIDC_ADMIN_ROLE = "admin";
          };
          environmentFiles = [ config.sops.templates."pinepods.env".path ];
          ports = [ "127.0.0.1:${toString port}:8040" ];
          networks = [ "slirp4netns:allow_host_loopback=true" ];
          volumes = [ "${downloadsDir}:/opt/pinepods/downloads:rw" ];
          extraOptions = [
            "--cap-drop=all"
            # The upstream entrypoint starts as root, prepares writable paths,
            # remaps its runtime user, and then drops to PUID:PGID with su-exec.
            "--cap-add=CHOWN"
            "--cap-add=DAC_OVERRIDE"
            "--cap-add=SETGID"
            "--cap-add=SETUID"
            "--security-opt=no-new-privileges"
          ];
        };
      };
    };

    systemd.services.podman-pinepods = {
      requires = [
        "pinepods-postgresql-password.service"
        "pinepods-valkey.service"
      ];
      wants = dependencies;
      after = dependencies;
      path = [ pkgs.slirp4netns ];
      environment.PINEPODS_LISTEN_PORT = toString port;
    };
  };
}
