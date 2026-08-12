{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.sudo.sshPasswordAuth;
  sshSudoAskpass = pkgs.writeShellScript "sudo-ssh-askpass" ''
    prompt="$1"
    [ -n "$prompt" ] || prompt="Password:"

    if [ ! -r /dev/tty ]; then
      exit 1
    fi

    printf "%s" "$prompt" > /dev/tty
    saved_tty="$(stty -g < /dev/tty)" || exit 1
    trap 'stty "$saved_tty" < /dev/tty 2>/dev/null' EXIT HUP INT TERM
    stty -echo < /dev/tty
    IFS= read -r password < /dev/tty
    printf "\n" > /dev/tty
    printf "%s\n" "$password"
  '';
in
{
  options.host.hm.sudo.sshPasswordAuth.enable =
    lib.mkEnableOption "password-authenticated sudo in SSH sessions";

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enable || osConfig.host.isDarwin;
          message = "host.hm.sudo.sshPasswordAuth is only supported on Darwin.";
        }
        {
          assertion = !cfg.enable || osConfig.host.security.sudo.sshPasswordAuth.enable;
          message = "host.hm.sudo.sshPasswordAuth requires host.security.sudo.sshPasswordAuth.";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      programs.zsh.initContent = lib.mkAfter ''
        sudo() {
          if [[ -n "''${SSH_CONNECTION:-}" && -t 0 && -t 1 ]]; then
            local arg

            for arg in "$@"; do
              case "$arg" in
                -A|--askpass|-S|--stdin|-n|--non-interactive)
                  command sudo "$@"
                  return
                  ;;
              esac
            done

            if (( $# == 1 )) && [[ "$1" == "-k" || "$1" == "-K" || "$1" == "--reset-timestamp" || "$1" == "--remove-timestamp" ]]; then
              command sudo "$@"
              return
            fi

            SUDO_ASKPASS=${sshSudoAskpass} command sudo -A "$@"
          else
            command sudo "$@"
          fi
        }
      '';
    })
  ];
}
