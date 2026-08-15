{
  config,
  lib,
  ...
}:
let
  cfg = config.host.vikunja;
  port = 3456;
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
    inherit cfg port;
    localUrl = "http://127.0.0.1:${toString port}";
    publicHost = "vi.${config.host.network.publicDomain}";
    metricsPort = 9345;
  };
}
