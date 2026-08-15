{
  config,
  lib,
  ...
}:
let
  clientModule = {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "torrent"
          "usenet"
        ];
        description = "Download protocol implemented by this client.";
      };

      implementation = lib.mkOption {
        type = lib.types.enum [
          "transmission"
          "sabnzbd"
        ];
        description = "Client implementation used to translate integration settings.";
      };

      endpoint = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Host-local API endpoint for service integrations.";
      };

      authentication = {
        type = lib.mkOption {
          type = lib.types.enum [
            "none"
            "api-key"
          ];
          default = "none";
        };

        secret = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "sops secret containing the client credential.";
        };
      };

      storageDefaults = {
        owner = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
        };
        group = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
        };
        mode = lib.mkOption {
          type = with lib.types; nullOr (strMatching "[0-7]{4}");
          default = null;
        };
      };
    };
  };

  routeModule = {
    options = {
      client = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Registered download client handling this route.";
      };

      label = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Torrent label assigned to downloads on this route.";
      };

      category = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Usenet category assigned to downloads on this route.";
      };

      storage = {
        claim = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Storage claim containing downloads on this route.";
        };

        relativePath = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Download path below the selected storage claim.";
        };
      };
    };
  };

  clients = config.host.downloads.clients;
  routes = config.host.downloads.routes;
in
{
  options.host.downloads = {
    clients = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule clientModule);
      default = { };
      description = "Download clients available to host-local consumers.";
    };

    routes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule routeModule);
      default = { };
      description = "Deployment-selected download routes.";
    };
  };

  config = {
    assertions =
      lib.mapAttrsToList (name: client: {
        assertion =
          (client.authentication.type == "none" && client.authentication.secret == null)
          || (client.authentication.type == "api-key" && client.authentication.secret != null);
        message = "host.downloads.clients.${name} has inconsistent authentication settings";
      }) clients
      ++ lib.mapAttrsToList (
        name: route:
        let
          client = clients.${route.client} or null;
        in
        {
          assertion = client != null;
          message = "host.downloads.routes.${name} selects unknown client '${route.client}'";
        }
      ) routes
      ++ lib.mapAttrsToList (
        name: route:
        let
          client = clients.${route.client} or null;
        in
        {
          assertion =
            client == null
            || (client.kind == "torrent" && route.label != null && route.category == null)
            || (client.kind == "usenet" && route.category != null && route.label == null);
          message = "host.downloads.routes.${name} must define metadata appropriate for its client kind";
        }
      ) routes;

    host.storage.claims = lib.mkMerge (
      lib.mapAttrsToList (
        _: route:
        let
          client = clients.${route.client};
        in
        {
          ${route.storage.claim}.directories.${route.storage.relativePath} = client.storageDefaults;
        }
      ) (lib.filterAttrs (_: route: builtins.hasAttr route.client clients) routes)
    );
  };
}
