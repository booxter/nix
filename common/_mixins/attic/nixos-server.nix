{
  config,
  lib,
  storageModel,
  ...
}:
let
  isServer = builtins.hasAttr config.networking.hostName config.host.attic.realmServers;
  databaseName = "attic";
  serviceName = "atticd";
  storagePath = storageModel.localResources.attic.sourcePath;
  serverTokenSecret = "attic/serverToken";
  listenAddress = "127.0.0.1:8082";
  localAliases = [ "attic" ];
  webService = config.host.web.services.atticd;
in
{
  config = lib.mkIf isServer {
    host = {
      backups.sources.attic = {
        title = "Attic";
        database = {
          type = "postgresql";
          name = databaseName;
          stagingDir = "/var/lib/attic-backup/latest";
        };
      };

      web.services.atticd = {
        upstream = "http://${listenAddress}";
        internal = {
          inherit localAliases;
          locationExtraConfig = ''
            client_max_body_size 0;
            proxy_request_buffering off;
            proxy_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
          '';
        };
      };
    };

    services = {
      atticd = {
        enable = true;
        environmentFile = config.sops.templates."atticd.env".path;
        settings = {
          allowed-hosts = [
            webService.internal.serverName
          ]
          ++ localAliases
          ++ map (alias: "${alias}.local") localAliases
          ++ [ listenAddress ];
          api-endpoint = "${webService.internal.url}/";
          listen = listenAddress;
          jwt = { };

          database = {
            url = "postgresql://${databaseName}@localhost/${databaseName}?host=/run/postgresql";
            heartbeat = true;
          };

          garbage-collection = {
            interval = "12 hours";
            default-retention-period = "3 months";
          };

          # Changing these values prevents existing chunks from being reused for
          # newly uploaded NARs until the cache gradually deduplicates again.
          chunking = {
            nar-size-threshold = 256 * 1024;
            min-size = 64 * 1024;
            avg-size = 256 * 1024;
            max-size = 1024 * 1024;
          };

          storage = {
            type = "local";
            path = storagePath;
          };
        };
      };

      postgresql = {
        enable = true;
        authentication = lib.mkBefore ''
          local ${databaseName} ${databaseName} peer map=attic
        '';
        identMap = lib.mkBefore ''
          attic ${serviceName} ${databaseName}
        '';
        ensureDatabases = [ databaseName ];
        ensureUsers = [
          {
            name = databaseName;
            ensureDBOwnership = true;
          }
        ];
      };
    };

    sops = {
      secrets.${serverTokenSecret} = {
        owner = serviceName;
        group = serviceName;
        mode = "0400";
        restartUnits = [ "atticd.service" ];
      };
      templates."atticd.env" = {
        owner = serviceName;
        group = serviceName;
        mode = "0400";
        content = ''
          ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=${config.sops.placeholder.${serverTokenSecret}}
        '';
        restartUnits = [ "atticd.service" ];
      };
    };

    systemd.services.atticd = {
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      environment.RUST_LOG = "attic_server::gc=info";
      unitConfig.RequiresMountsFor = storagePath;
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        CPUWeight = 50;
        IOWeight = 25;
        MemoryHigh = "8G";
        MemoryMax = "12G";
      };
    };
  };
}
