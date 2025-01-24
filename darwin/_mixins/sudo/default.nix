{ pkgs, ... }: {
  # Disable nix-darwin touch sudo implementation because it doesn't configure
  # reattach
  security.pam.enableSudoTouchIdAuth = false;
  environment.etc."pam.d/sudo_local".text = ''
    # PAM for tmux touchid; must go before _tid.so
    auth       optional     ${pkgs.pam-reattach}/lib/pam/pam_reattach.so
    # Base touchid pam module
    auth       sufficient   pam_tid.so
  '';

  # Set sudo timeout to 30 minutes
  security.sudo.extraConfig = "Defaults    timestamp_timeout=30";
}
