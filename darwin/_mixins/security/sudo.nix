{
  config,
  lib,
  pkgs,
  ...
}:
{
  security = {
    sudo.extraConfig = ''
      Defaults:${config.host.username} env_keep+=SSH_AUTH_SOCK
    '';

    # Try the originating operator's agent before prompting on this Mac.
    pam.services.sudo_local.text = lib.mkBefore ''
      auth sufficient ${pkgs.pam_rssh}/lib/libpam_rssh.dylib auth_key_file=/etc/sudo/authorized_keys/$ruser
    '';
  };
}
