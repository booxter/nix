{
  config,
  lib,
  pkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.seerr;
  oldStateDir = "${config.host.srvarr.stateDir}/jellyseerr";
in
{
  services.seerr = {
    enable = true;
    configDir = cfg.stateDir;
    port = cfg.port;
  };

  system.activationScripts.migrate-seerr-user = {
    text = ''
      if ${pkgs.gnugrep}/bin/grep -q '^jellyseerr:' /etc/passwd && ! ${pkgs.gnugrep}/bin/grep -q '^seerr:' /etc/passwd; then
        echo "srvarr: renaming jellyseerr user to seerr in /etc/passwd"
        ${pkgs.gnused}/bin/sed -i --follow-symlinks 's/^jellyseerr:/seerr:/' /etc/passwd
      fi
      if ${pkgs.gnugrep}/bin/grep -q '^jellyseerr:' /etc/group && ! ${pkgs.gnugrep}/bin/grep -q '^seerr:' /etc/group; then
        echo "srvarr: renaming jellyseerr group to seerr in /etc/group"
        ${pkgs.gnused}/bin/sed -i --follow-symlinks 's/^jellyseerr:/seerr:/' /etc/group
      fi
    '';
  };

  system.activationScripts.users =
    lib.mkIf
      (!(config.systemd.sysusers.enable or false) && !(config.services.userborn.enable or false))
      {
        deps = lib.mkAfter [ "migrate-seerr-user" ];
      };

  system.activationScripts.migrate-seerr-state = {
    deps = [ "users" ];
    text = ''
      if [ -d "${oldStateDir}" ] && [ ! -e "${cfg.stateDir}" ]; then
        echo "srvarr: migrating Seerr state directory from ${oldStateDir} to ${cfg.stateDir}"
        mv "${oldStateDir}" "${cfg.stateDir}"
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
  ];

  systemd.services.seerr.serviceConfig = {
    DynamicUser = lib.mkForce false;
    Group = cfg.group;
    ReadWritePaths = [ cfg.stateDir ];
    StateDirectory = lib.mkForce "seerr";
    User = cfg.user;
  };

  users.groups.${cfg.group}.gid = accounts.gids.seerr;
  users.users.${cfg.user} = {
    group = cfg.group;
    home = "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.seerr;
  };
}
