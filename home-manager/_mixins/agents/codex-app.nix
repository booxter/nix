{
  config,
  inputs,
  pkgs,
  ...
}:
let
  codexDesktopLinuxPackage =
    (inputs.codex-desktop-linux.packages.${pkgs.stdenv.hostPlatform.system}.codex-desktop.override {
      enableComputerUseUi = true;
      linuxFeatureIds = [ "remote-mobile-control" ];
    }).overrideAttrs
      (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.asar ];
        # The remote-mobile-control patch mistakes the function-local
        # __codexChild binding from the external-open patch for a module-level
        # child_process binding. Repair its one global use until upstream fixes
        # the patch interaction; --replace-fail makes upstream drift explicit.
        postInstall = (old.postInstall or "") + ''
          resources="$out/opt/codex-desktop/resources"
          extracted="$TMPDIR/codex-desktop-app-fixed"
          asar extract "$resources/app.asar" "$extracted"
          mainBundle="$(find "$extracted/.vite/build" -maxdepth 1 -name 'main-*.js' -print -quit)"
          substituteInPlace "$mainBundle" \
            --replace-fail '__codexChild.spawn(codexLinuxRemoteControlFlockPath' \
              'require(`node:child_process`).spawn(codexLinuxRemoteControlFlockPath'

          rm -f "$resources/app.asar"
          rm -rf "$resources/app.asar.unpacked"
          (cd "$extracted" && find . -type f | LC_ALL=C sort | sed 's#^./##') \
            > "$TMPDIR/codex-desktop-app-fixed.ordering"
          asar pack "$extracted" "$resources/app.asar" \
            --ordering "$TMPDIR/codex-desktop-app-fixed.ordering" \
            --unpack "{*.node,*.so,*.dylib}"
        '';
      });
in
{
  imports = [ inputs.codex-desktop-linux.homeManagerModules.default ];

  programs.codexDesktopLinux = {
    enable = true;
    cliPackage = config.programs.codex.package;
    package = codexDesktopLinuxPackage;
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
