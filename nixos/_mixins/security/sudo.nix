{
  config,
  lib,
  sshKeys,
  ...
}:
let
  username = config.host.username;
in
{
  environment.etc."sudo/authorized_keys/${username}".text = lib.concatMapStrings (
    key: "${key}\n"
  ) sshKeys.sudo;

  security = {
    sudo = {
      wheelNeedsPassword = lib.mkDefault true;
      # Let sudo -n authenticate through the forwarded agent. Hardware approval
      # happens on the SSH client without reading the helper's stdin.
      extraConfig = ''
        Defaults:${username} noninteractive_auth
      '';
    };

    pam = {
      rssh = {
        enable = true;
        settings.auth_key_file = "/etc/sudo/authorized_keys/$ruser";
      };
      services.sudo.rssh = true;
    };
  };
}
