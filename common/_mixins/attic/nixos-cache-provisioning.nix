{
  config,
  lib,
  pkgs,
  ...
}:
let
  localServer = config.host.attic.realmServers.${config.networking.hostName} or null;
  cacheName = localServer.cacheName;
  unitName = "atticd-cache-${cacheName}";
  runtimeDirectory = unitName;
  tokenFile = "/run/${runtimeDirectory}/token";
  localEndpoint = "http://${config.services.atticd.settings.listen}";
  serverConfigFile =
    (pkgs.formats.toml { }).generate "attic-server-provision.toml"
      config.services.atticd.settings;
  clientConfigFile = (pkgs.formats.toml { }).generate "attic-client-${cacheName}.toml" {
    default-server = "local";
    servers.local = {
      endpoint = localEndpoint;
      token-file = tokenFile;
    };
  };
  clientConfigDirectory = pkgs.linkFarm "attic-client-${cacheName}-config" [
    {
      name = "attic/config.toml";
      path = clientConfigFile;
    }
  ];
  cacheSettingsArgs = [
    "--priority"
    "41"
    "--store-dir"
    "/nix/store"
  ];
  upstreamCacheArgs = [
    "--upstream-cache-key-name"
    "cache.nixos.org-1"
  ];
  createArgs = [
    "cache"
    "create"
    cacheName
  ]
  ++ cacheSettingsArgs
  ++ [ "--public" ]
  ++ upstreamCacheArgs;
  configureArgs = [
    "cache"
    "configure"
    cacheName
    "--public"
  ]
  ++ cacheSettingsArgs
  ++ upstreamCacheArgs
  ++ [ "--reset-retention-period" ];
  provision = pkgs.writeShellApplication {
    name = "atticd-cache-${cacheName}-provision";
    runtimeInputs = [
      config.services.atticd.package
      pkgs.attic-client
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      token_file="$RUNTIME_DIRECTORY/token"
      authorization_header="$RUNTIME_DIRECTORY/authorization-header"
      response_file="$RUNTIME_DIRECTORY/response"

      umask 077
      trap 'rm -f "$token_file" "$authorization_header"' EXIT
      atticadm -f ${serverConfigFile} make-token \
        --sub ${lib.escapeShellArg "system:cache-provisioner:${cacheName}"} \
        --validity "5 minutes" \
        --pull ${lib.escapeShellArg cacheName} \
        --create-cache ${lib.escapeShellArg cacheName} \
        --configure-cache ${lib.escapeShellArg cacheName} \
        --configure-cache-retention ${lib.escapeShellArg cacheName} \
        >"$token_file"
      printf 'Authorization: Bearer %s\n' "$(<"$token_file")" >"$authorization_header"

      status="$(curl \
        --silent \
        --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --retry 20 \
        --retry-all-errors \
        --retry-delay 1 \
        --header "@$authorization_header" \
        ${lib.escapeShellArg "${localEndpoint}/_api/v1/cache-config/${cacheName}"})"

      case "$status" in
        200)
          ;;
        404)
          attic ${lib.escapeShellArgs createArgs}
          ;;
        *)
          printf 'Attic cache probe returned HTTP %s: ' "$status" >&2
          cat "$response_file" >&2
          exit 1
          ;;
      esac

      attic ${lib.escapeShellArgs configureArgs}
    '';
  };
in
{
  config = lib.mkIf (localServer != null) {
    systemd.services.${unitName} = {
      description = "Create and configure the ${cacheName} Attic cache";
      wantedBy = [ "multi-user.target" ];
      after = [ "atticd.service" ];
      requires = [ "atticd.service" ];
      environment.XDG_CONFIG_HOME = clientConfigDirectory;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 5;
        ExecStart = lib.getExe provision;
        EnvironmentFile = config.services.atticd.environmentFile;
        User = config.services.atticd.user;
        Group = config.services.atticd.group;
        RuntimeDirectory = runtimeDirectory;
        RuntimeDirectoryMode = "0700";
      };
    };
  };
}
