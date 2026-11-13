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
  ) sshKeys.sudo.${config.host.realm};

  security.sudo.extraConfig = ''
    Defaults:${username} timestamp_type=global, timestamp_timeout=15
    # Hardware approval does not need a terminal password prompt.
    Defaults:${username} noninteractive_auth
  '';
}
