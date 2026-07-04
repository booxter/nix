{
  config,
  lib,
  pkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  group = "media";
  stateDir = "${config.host.srvarrPaths.stateDir}/bazarr";
  user = "bazarr";
  enforceBazarrAuthConfig = pkgs.writeShellApplication {
    name = "enforce-bazarr-auth-config";
    runtimeInputs = [ pkgs.yq-go ];
    text = ''
      set -euo pipefail

      config_file=${lib.escapeShellArg "${stateDir}/config/config.yaml"}
      config_dir="$(dirname "$config_file")"

      install -d -m 0700 -o ${user} -g ${group} "$config_dir"
      if [[ ! -s "$config_file" ]]; then
        printf '{}\n' > "$config_file"
      fi

      tmp="$(mktemp "$config_dir/config.yaml.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT

      yq eval '.auth.type = null | .auth.username = "" | .auth.password = ""' "$config_file" > "$tmp"
      install -m 0600 -o ${user} -g ${group} "$tmp" "$config_file"
    '';
  };
in
{
  services.bazarr = {
    enable = true;
    dataDir = stateDir;
    group = group;
    user = user;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  users.users.${user} = {
    extraGroups = lib.mkForce [ "media" ];
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.bazarr;
  };

  systemd.services.bazarr.serviceConfig.ExecStartPre = "+${lib.getExe enforceBazarrAuthConfig}";

  host.internalHttps.services.bazarr = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.bazarr.listenPort}";
  };
}
