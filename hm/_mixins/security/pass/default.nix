{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.pass;
in
{
  options.host.hm.pass.enable = lib.mkEnableOption "password-store environment";

  config = lib.mkIf cfg.enable {
    programs = {
      gpg.enable = true;

      password-store = {
        enable = true;
        settings = {
          # Restore pass location to what was before https://github.com/nix-community/home-manager/pull/7833
          PASSWORD_STORE_DIR = "${config.xdg.dataHome}/password-store";
        };
      };
    };

    services.gpg-agent = {
      enable = true;
      enableSshSupport = false; # it's not 1:1 compatible and can mess output of `ssh-add -l`.
      enableZshIntegration = true;
      pinentry.package = pkgs.pinentry-tty;
    };

    # Home Manager's Darwin socket activation is broken; see
    # https://github.com/nix-community/home-manager/pull/5901. GnuPG starts
    # gpg-agent on demand when pass or another client first needs it. Linux
    # likely does not need its systemd unit either, but keep Home Manager's
    # default there until that path is validated separately.
    launchd.agents.gpg-agent.enable = lib.mkForce false;
  };
}
