{
  config,
  lib,
  ...
}:
let
  cfg = config.host.vikunja;
in
{
  imports = [
    ./secrets.nix
    ./service.nix
    ./web.nix
  ];

  options.host.vikunja = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
    description = "Vikunja task management service configuration.";
  };

  config._module.args.vikunjaModel = {
    inherit cfg;
    port = 3456;
    localUrl = "http://127.0.0.1:3456";
    publicHost = "vi.${config.host.network.publicDomain}";
    metricsPort = 9345;
  };
}
