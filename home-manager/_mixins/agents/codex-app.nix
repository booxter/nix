{
  config,
  inputs,
  ...
}:
{
  imports = [ inputs.codex-desktop-linux.homeManagerModules.default ];

  programs.codexDesktopLinux = {
    enable = true;
    cliPackage = config.programs.codex.package;
    computerUseUi.enable = true;
    remoteMobileControl.enable = true;
    # The patched Desktop app-server is the remote-control owner. A separate
    # remoteControl service races it for the same backend environment and makes
    # Desktop pairing fail with HTTP 409 "Remote app server already online".
  };

  # The remote-mobile-control Linux device-key provider rejects outbound
  # authorization unless this directory is exactly 0700, but the app creates
  # it as 0755. Keep the correction declarative until upstream fixes creation.
  systemd.user.tmpfiles.rules = [
    "d %h/.config/codex-desktop 0700 - - -"
  ];
}
