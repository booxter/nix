{
  config,
  lib,
  ...
}:
let
  databaseName = "attic";
  databaseRole = "attic";
  serviceName = "atticd";
  storagePath = "/volume2/attic";
  serverTokenSecret = "attic/serverToken";
in
{
  host = {
    attic.server = {
      enable = true;
      databaseUrl = "postgresql://${databaseRole}@localhost/${databaseName}?host=/run/postgresql";
      environmentFile = config.sops.templates."atticd.env".path;
      localAliases = [ "attic" ];
      inherit storagePath;
      chunking = {
        narSizeThreshold = 256 * 1024;
        minSize = 64 * 1024;
        avgSize = 256 * 1024;
        maxSize = 1024 * 1024;
      };
    };

    backups.sources.attic = {
      title = "Attic";
      database = {
        type = "postgresql";
        name = databaseName;
        stagingDir = "/var/lib/attic-backup/latest";
      };
    };
  };

  services = {
    atticd = {
      settings = {
        allowed-hosts = [
          "attic.home.arpa"
          "attic"
          "attic.local"
        ];
        api-endpoint = "https://attic.home.arpa/";
      };
    };

    postgresql = {
      enable = true;
      authentication = lib.mkBefore ''
        local ${databaseName} ${databaseRole} peer map=attic
      '';
      identMap = lib.mkBefore ''
        attic ${serviceName} ${databaseRole}
      '';
      ensureDatabases = [ databaseName ];
      ensureUsers = [
        {
          name = databaseRole;
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
        ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=${config.sops.placeholder.${serverTokenSecret}}
      '';
      restartUnits = [ "atticd.service" ];
    };
  };

  systemd.services.atticd = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    environment.RUST_LOG = "attic_server::gc=info";
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      CPUWeight = 50;
      IOWeight = 25;
      MemoryHigh = "8G";
      MemoryMax = "12G";
    };
  };
}
