{
  config,
  lib,
  pkgs,
  ...
}:
let
  clientConfig = (pkgs.formats.toml { }).generate "attic-ci.toml" {
    default-server = "ci";
    servers.ci = {
      endpoint = config.host.attic.realmServers.beast.caches.github.endpoint;
      token = config.sops.placeholder."attic/ci_token";
    };
  };
in
{
  options.host.attic.ci.enable = lib.mkEnableOption "public cache uploads from CI jobs";

  config = lib.mkIf config.host.attic.ci.enable {
    sops.secrets."attic/ci_token" = { };
    sops.templates."attic-ci.toml" = {
      file = clientConfig;
      mode = "0400";
      # Linux hands the root-owned config to each runner through LoadCredential.
      owner = if pkgs.stdenv.isDarwin then "_github-runner" else "root";
    };
  };
}
