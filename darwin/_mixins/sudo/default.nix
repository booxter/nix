{ ... }: {
  security.pam.services.sudo_local.touchIdAuth = true;
  security.pam.services.sudo_local.reattach = true;

  # Set sudo timeout to 30 minutes
  security.sudo.extraConfig = "Defaults    timestamp_timeout=30";
}
