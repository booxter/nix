{ config, ... }:
{
  security.sudo.extraConfig = ''
    Defaults:${config.host.username} timestamp_type=global, timestamp_timeout=15
  '';
}
