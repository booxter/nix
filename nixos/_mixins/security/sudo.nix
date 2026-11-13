{
  lib,
  ...
}:
{
  security = {
    sudo.wheelNeedsPassword = lib.mkDefault true;

    pam = {
      rssh = {
        enable = true;
        settings.auth_key_file = "/etc/sudo/authorized_keys/$ruser";
      };
      services.sudo.rssh = true;
    };
  };
}
