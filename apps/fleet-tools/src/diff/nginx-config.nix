let
  flake = builtins.getFlake (builtins.getEnv "DIFF_FLAKE_REF");
  name = builtins.getEnv "DIFF_MACHINE";
  configuration = (builtins.getAttr name flake.nixosConfigurations).config;
  nginx = configuration.services.nginx;
  execStart = configuration.systemd.services.nginx.serviceConfig.ExecStart;
  configMatch = builtins.match ".* -c '([^']+)'.*" execStart;
in
if !nginx.enable then
  ""
else if nginx.enableReload then
  toString configuration.environment.etc."nginx/nginx.conf".source
else if configMatch != null then
  builtins.head configMatch
else
  throw "Unable to find the rendered nginx config in ExecStart: ${execStart}"
