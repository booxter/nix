{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    cfg
    cloudGroup
    enabledOffloads
    ingestUser
    offloadUser
    repositoryPath
    sshRepositories
    ;
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.restic ];

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      name: _:
      let
        owner = if name == cfg.localClient then cloudGroup else ingestUser name;
      in
      "d ${repositoryPath name} 0750 ${owner} ${owner} - -"
    ) cfg.repositories;

    users.groups =
      lib.optionalAttrs (enabledOffloads != { }) {
        ${cloudGroup} = { };
      }
      // lib.mapAttrs' (name: _: lib.nameValuePair (ingestUser name) { }) sshRepositories
      // lib.mapAttrs' (name: _: lib.nameValuePair (offloadUser name) { }) (
        lib.filterAttrs (name: _: name != cfg.localClient) enabledOffloads
      );

    users.users =
      lib.optionalAttrs (enabledOffloads != { }) {
        ${cloudGroup} = {
          isSystemUser = true;
          group = cloudGroup;
          createHome = false;
          home = cfg.repositoryRoot;
          shell = pkgs.bash;
        };
      }
      // lib.mapAttrs' (
        name: repository:
        lib.nameValuePair (ingestUser name) {
          isSystemUser = true;
          group = ingestUser name;
          createHome = false;
          home = cfg.repositoryRoot;
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = [ repository.publicKey ];
        }
      ) sshRepositories
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair (offloadUser name) {
          isSystemUser = true;
          group = offloadUser name;
          createHome = false;
          home = cfg.repositoryRoot;
          shell = pkgs.bash;
          extraGroups = [ cloudGroup ];
        }
      ) (lib.filterAttrs (name: _: name != cfg.localClient) enabledOffloads);

    services.openssh = {
      enable = true;
      extraConfig = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: _: ''
          Match User ${ingestUser name}
            ForceCommand internal-sftp
            PasswordAuthentication no
            PermitTTY no
            X11Forwarding no
            AllowTcpForwarding no
        '') sshRepositories
      );
    };
  };
}
