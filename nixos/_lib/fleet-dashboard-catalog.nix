{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  hostConfigs = lib.mapAttrs (_: configuration: configuration.config) otherConfigurations // {
    ${localHost} = config;
  };
  web = import ./fleet-web-services.nix { inherit config lib outputs; };
  webEntries = map (
    contribution:
    let
      service = contribution.value;
      endpoint = exposure: {
        url = service.${exposure}.url;
        checkUrl =
          if service.health.frontend.enable then
            "${service.${exposure}.url}${service.health.frontend.path}"
          else
            null;
      };
    in
    {
      inherit (contribution) id owner;
      title = service.displayName;
      inherit (service.dashboard) icon section;
      endpoints = {
        internal = endpoint "internal";
        public = if service.public.enable then endpoint "public" else null;
      };
    }
  ) web.dashboard;
  directEntries = builtins.concatLists (
    lib.mapAttrsToList (
      owner: hostConfig:
      lib.mapAttrsToList (id: entry: {
        inherit id owner;
        inherit (entry)
          icon
          section
          title
          ;
        endpoints = {
          internal = {
            inherit (entry) checkUrl url;
          };
          public = null;
        };
      }) hostConfig.host.dashboard.entries
    ) hostConfigs
  );
in
import ../_mixins/dashboard/model.nix { inherit directEntries lib webEntries; }
