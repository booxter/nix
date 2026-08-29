{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.attic.server;
  listenAddress = "127.0.0.1:8080";
  localEndpoint = "http://${listenAddress}";
  serverConfigFile =
    (pkgs.formats.toml { }).generate "attic-server-provision.toml"
      config.services.atticd.settings;
  cacheProvisioners = lib.mapAttrs' (
    cacheName: cache:
    let
      unitName = "atticd-cache-${cacheName}";
      runtimeDirectory = unitName;
      tokenFile = "/run/${runtimeDirectory}/token";
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
      visibilityFlag = if cache.public then "--public" else "--private";
      upstreamKeyArgs = lib.concatMap (keyName: [
        "--upstream-cache-key-name"
        keyName
      ]) cache.upstreamCacheKeyNames;
      createArgs = [
        "cache"
        "create"
        cacheName
        "--priority"
        (toString cache.priority)
        "--store-dir"
        cache.storeDir
      ]
      ++ lib.optional cache.public "--public"
      ++ upstreamKeyArgs;
      configureArgs = [
        "cache"
        "configure"
        cacheName
        visibilityFlag
        "--priority"
        (toString cache.priority)
        "--store-dir"
        cache.storeDir
      ]
      ++ upstreamKeyArgs
      ++ (
        if cache.retentionPeriod == null then
          [ "--reset-retention-period" ]
        else
          [
            "--retention-period"
            cache.retentionPeriod
          ]
      );
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
    lib.nameValuePair unitName {
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
        EnvironmentFile = cfg.environmentFile;
        User = config.services.atticd.user;
        Group = config.services.atticd.group;
        RuntimeDirectory = runtimeDirectory;
        RuntimeDirectoryMode = "0700";
      };
    }
  ) cfg.caches;
in
{
  config = lib.mkIf (cfg.enable && cfg.caches != { }) {
    services.atticd.settings.allowed-hosts = lib.mkAfter [ listenAddress ];
    systemd.services = cacheProvisioners;
  };
}
