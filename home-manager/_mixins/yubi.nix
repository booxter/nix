{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.yubi;
  residentSsh = hostInventory.yubi.devices.personal.applets.fido2.residentSsh;
  yubikeySshKey = "${config.home.homeDirectory}/.ssh/${cfg.ssh.keyName}";
  fallbackSshKey = "${config.home.homeDirectory}/.ssh/${cfg.ssh.remoteFallbackKeyName}";
  yubikeyAgeIdentityFile = "${config.home.homeDirectory}/.config/sops/age/${cfg.age.identityFileName}";
  localSshIdentityConfig =
    if cfg.ssh.localOnly then
      ''
        Match exec "test -z \"$SSH_CONNECTION\""
          IdentityFile ${yubikeySshKey}
          IdentitiesOnly yes

        Match exec "test -n \"$SSH_CONNECTION\""
          IdentityFile ${fallbackSshKey}
          IdentitiesOnly yes
          IdentityAgent none

        Host *
      ''
    else
      ''
        Host *
          IdentityFile ${yubikeySshKey}
          IdentitiesOnly yes
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
  options.programs.yubi = {
    ssh = {
      enable = lib.mkEnableOption "YubiKey-backed resident SSH key defaults";

      keyName = lib.mkOption {
        type = lib.types.str;
        default = residentSsh.keyName;
        description = "Resident SSH key stub filename under ~/.ssh.";
      };

      localOnly = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to use the YubiKey SSH identity only outside SSH login sessions.";
      };

      remoteFallbackKeyName = lib.mkOption {
        type = lib.types.str;
        default = "id_ed25519";
        description = "Password-protected SSH key filename under ~/.ssh for SSH login sessions.";
      };
    };

    age = {
      enable = lib.mkEnableOption "YubiKey-backed age identity tooling";

      identityFileName = lib.mkOption {
        type = lib.types.str;
        default = "yubi-nix.txt";
        description = "YubiKey age identity filename under ~/.config/sops/age.";
      };
    };

    smartCard = {
      sshSudoPassword = {
        enable = lib.mkEnableOption "password-only sudo authentication for interactive SSH sessions";
      };
    };
  };

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

    (lib.mkIf cfg.smartCard.sshSudoPassword.enable {
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
