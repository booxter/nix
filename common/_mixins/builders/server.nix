{
  config,
  lib,
  sshKeys,
  system,
  ...
}:
let
  builder = config.host.nix.builder;
  enabled = config.host.realm == "home" && builder != null;
  clients = lib.filterAttrs (
    name: _: name != "ci" || builtins.elem "ci" builder.uses
  ) sshKeys.builders;
  command = "${lib.getExe' config.nix.package "nix-daemon"} --stdio";
  keys = map (key: ''restrict,command="${command}" ${key}'') (builtins.attrValues clients);
  darwin = lib.hasSuffix "-darwin" system;
in
{
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        nix.settings.allowed-users = [ "nix-ssh" ];
        assertions = [
          {
            assertion = !(builtins.elem "nix-ssh" config.nix.settings.trusted-users);
            message = "The SSH builder account must remain untrusted by the Nix daemon.";
          }
        ];

        services.openssh.extraConfig = ''
          Match User nix-ssh
            AuthenticationMethods publickey
            DisableForwarding yes
            PermitUserRC no
          Match All
        '';
      }
      (lib.optionalAttrs (!darwin) {
        nix.sshServe = {
          enable = true;
          protocol = "ssh-ng";
          trusted = false;
          inherit keys;
        };
      })
      (lib.optionalAttrs darwin {
        ids.uids.nix-ssh = 538;
        ids.gids.nix-ssh = 538;
        users = {
          users.nix-ssh = {
            uid = config.ids.uids.nix-ssh;
            gid = config.ids.gids.nix-ssh;
            home = "/var/empty";
            createHome = false;
            isHidden = true;
            shell = "/bin/bash";
            description = "Remote Nix builds";
            openssh.authorizedKeys.keys = keys;
          };
          groups.nix-ssh.gid = config.ids.gids.nix-ssh;
          knownUsers = [ "nix-ssh" ];
          knownGroups = [ "nix-ssh" ];
        };

        services.openssh.extraConfig = lib.mkAfter ''
          Match User nix-ssh
            ForceCommand ${command}
            PermitTTY no
          Match All
        '';

        # Apple's Remote Login allowlist is checked by PAM independently of
        # authorized_keys. Preserve its existing members and all-users mode.
        system.activationScripts.users.text = lib.mkAfter ''
          if /usr/bin/dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
            /usr/sbin/dseditgroup -o edit -a nix-ssh -t user com.apple.access_ssh
          fi
        '';
      })
    ]
  );
}
