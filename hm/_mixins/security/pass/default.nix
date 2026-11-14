{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.pass;
in
{
  options.host.hm.pass = {
    enable = lib.mkEnableOption "password-store environment";
    idleTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Seconds of inactivity before pass stops scdaemon and gpg-agent to
        require fresh authorization. Enforced on the next secret operation.
        Null disables the wrapper.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs = {
      gpg.enable = true;

      password-store = {
        enable = true;
        package = lib.mkIf (cfg.idleTimeout != null) (
          pkgs.symlinkJoin {
            name = "pass-with-idle-timeout";
            paths = [ pkgs.pass ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              rm "$out/bin/pass"
              makeWrapper ${lib.getExe pkgs.pass-idle} "$out/bin/pass" \
                --add-flags ${
                  lib.escapeShellArg (
                    lib.escapeShellArgs [
                      "--pass-program"
                      (lib.getExe pkgs.pass)
                      "--gpgconf"
                      "${config.programs.gpg.package}/bin/gpgconf"
                      "--idle-seconds"
                      (toString cfg.idleTimeout)
                      "--"
                    ]
                  )
                }
            '';
            meta.mainProgram = "pass";
          }
        );
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
      pinentry.package =
        if pkgs.stdenv.hostPlatform.isDarwin then
          pkgs.pinentry_mac
        else if osConfig.host.desktop != null then
          pkgs.pinentry-qt
        else
          pkgs.pinentry-tty;
      # Ask pinentry to leave credential caching to the agent we reset on idle.
      noAllowExternalCache = true;
    };

    # Refresh pinentry's store path before the old path is garbage-collected.
    home.file."${config.programs.gpg.homedir}/gpg-agent.conf".onChange =
      lib.optionalString pkgs.stdenv.isDarwin ''
        agent_socket="$(${config.programs.gpg.package}/bin/gpgconf --list-dirs agent-socket)"
        if [[ -S "$agent_socket" ]]; then
          ${config.programs.gpg.package}/bin/gpgconf --reload gpg-agent
        fi
      '';

    # Home Manager's Darwin socket activation is broken; see
    # https://github.com/nix-community/home-manager/pull/5901. GnuPG starts
    # gpg-agent on demand when pass or another client first needs it. Linux
    # likely does not need its systemd unit either, but keep Home Manager's
    # default there until that path is validated separately.
    launchd.agents.gpg-agent.enable = lib.mkForce false;
  };
}
