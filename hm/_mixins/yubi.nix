{
  config,
  facts,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = osConfig.programs.yubi;
  residentSsh = facts.yubi.devices.personal.applets.fido2.residentSsh;
  yubikeySshKey = "${config.home.homeDirectory}/.ssh/${residentSsh.keyName}";
  fallbackSshKey = "${config.home.homeDirectory}/.ssh/id_ed25519";
  yubikeyAgeIdentityFile = "${config.xdg.configHome}/sops/age/${facts.yubi.ageIdentity.identityFileName}";
  sshSudoPasswordEnabled =
    osConfig.host.isDarwin && osConfig.programs.yubi.smartCard.sshSudoPassword.enable;
  localSshIdentityConfig = ''
    Match exec "test -z \"$SSH_CONNECTION\""
      IdentityFile ${yubikeySshKey}
      IdentitiesOnly yes

    Match exec "test -n \"$SSH_CONNECTION\""
      IdentityFile ${fallbackSshKey}
      IdentitiesOnly yes
      IdentityAgent none

    Host *
  '';
  gitSshSign = pkgs.writeShellScript "git-ssh-sign" ''
    args=("$@")

    if [[ -n "''${SSH_CONNECTION:-}" ]]; then
      for ((i = 0; i < ''${#args[@]}; i++)); do
        if [[ "''${args[i]}" == ${lib.escapeShellArg yubikeySshKey} ]]; then
          args[i]=${lib.escapeShellArg fallbackSshKey}
        fi
      done
    fi

    exec ${pkgs.openssh}/bin/ssh-keygen "''${args[@]}"
  '';
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
  config = lib.mkMerge [
    (lib.mkIf cfg.ssh.enable {
      programs.git.settings = {
        gpg.ssh.program = "${gitSshSign}";
        user.signingKey = yubikeySshKey;
      };
      programs.ssh.extraConfig = lib.mkAfter localSshIdentityConfig;
    })

    (lib.mkIf cfg.age.enable {
      home.packages = [ pkgs.age-plugin-yubikey ];
      home.sessionVariables.SOPS_AGE_KEY_FILE = lib.mkDefault yubikeyAgeIdentityFile;
    })

    (lib.mkIf sshSudoPasswordEnabled {
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
