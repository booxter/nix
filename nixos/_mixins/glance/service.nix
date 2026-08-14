{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.glance;
  model = import ./model.nix {
    inherit cfg lib;
    dashboardCatalog = import ../../_lib/fleet-dashboard-catalog.nix {
      inherit config lib outputs;
    };
    searchProviders = config.host.site.search.availableProviders;
  };
  unitNameFor = name: "glance-${name}";
  siteFor =
    entry:
    {
      inherit (entry) icon title;
      url = entry.endpoint.url;
    }
    // lib.optionalAttrs (entry.endpoint.checkUrl != null) {
      check-url = entry.endpoint.checkUrl;
    };
  monitorFor = section: {
    type = "monitor";
    cache = "1m";
    inherit (section) title;
    sites = map siteFor section.entries;
  };
  settingsFor = instance: {
    server = {
      host = "127.0.0.1";
      inherit (instance) port;
    };
    pages = [
      {
        name = "Startpage";
        width = "slim";
        hide-desktop-navigation = true;
        center-vertically = true;
        columns = [
          {
            size = "full";
            widgets = [
              {
                type = "search";
                autofocus = true;
                search-engine = "${instance.searchEndpoint.baseUrl}${instance.searchEndpoint.searchPath}?${instance.searchEndpoint.queryParameter}={QUERY}";
              }
            ]
            ++ map monitorFor instance.sections;
          }
        ];
      }
    ];
  };
  serviceFor = name: instance: {
    description = "Glance dashboard instance ${name}";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "nss-user-lookup.target"
    ];
    requires = [ "nss-user-lookup.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.glance} --config ${
        (pkgs.formats.yaml { }).generate "glance-${name}.yaml" (settingsFor instance)
      }";
      Restart = "on-failure";
      WorkingDirectory = "/var/lib/${unitNameFor name}";
      StateDirectory = unitNameFor name;
      PrivateTmp = true;
      DynamicUser = true;
      DevicePolicy = "closed";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      PrivateUsers = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProcSubset = "all";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };
in
{
  config.systemd.services = lib.mapAttrs' (
    name: instance: lib.nameValuePair (unitNameFor name) (serviceFor name instance)
  ) model.resolved;
}
