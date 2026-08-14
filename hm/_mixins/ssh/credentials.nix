{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  backend = osConfig.host.ssh.credentials.backend;
  enabled = osConfig.host.userEnvironment.roles.developer.enable;
  useSecretive = backend == "secretive";
  useYubikey = backend == "yubikey";
  secretiveSocket = "${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh";
  secretiveAuthSockInit = ''
    if [ -z "$SSH_AUTH_SOCK" -o -z "$SSH_CONNECTION" ]; then
      export SSH_AUTH_SOCK="${secretiveSocket}"
    fi
  '';
  yubikeyIdentityFile = "${config.home.homeDirectory}/.ssh/id_ed25519_sk_rk";
  remoteFallbackIdentityFile = "${config.home.homeDirectory}/.ssh/id_ed25519";
  yubikeyIdentityConfig = ''
    Match exec "test -z \"$SSH_CONNECTION\""
      IdentityFile ${yubikeyIdentityFile}
      IdentitiesOnly yes

    Match exec "test -n \"$SSH_CONNECTION\""
      IdentityFile ${remoteFallbackIdentityFile}
      IdentitiesOnly yes
      IdentityAgent none

    Host *
  '';
  gitSshSign = pkgs.writeShellScript "git-ssh-sign" ''
    args=("$@")

    if [[ -n "''${SSH_CONNECTION:-}" ]]; then
      for ((i = 0; i < ''${#args[@]}; i++)); do
        if [[ "''${args[i]}" == ${lib.escapeShellArg yubikeyIdentityFile} ]]; then
          args[i]=${lib.escapeShellArg remoteFallbackIdentityFile}
        fi
      done
    fi

    exec ${lib.getExe' pkgs.openssh "ssh-keygen"} "''${args[@]}"
  '';
in
{
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        programs.ssh.settings."*".AddKeysToAgent = if useSecretive then "no" else "yes";
      }
      (lib.mkIf useSecretive {
        home.file.".ssh/secretive.pub".text = osConfig.host.ssh.credentials.secretive.publicKey + "\n";
        programs.git.settings.user.signingKey = "${config.home.homeDirectory}/.ssh/secretive.pub";
        programs.bash = {
          profileExtra = lib.mkOrder 900 secretiveAuthSockInit;
          initExtra = lib.mkOrder 900 secretiveAuthSockInit;
        };
        programs.zsh.envExtra = lib.mkOrder 900 secretiveAuthSockInit;
      })
      (lib.mkIf useYubikey {
        programs.git.settings = {
          gpg.ssh.program = "${gitSshSign}";
          user.signingKey = yubikeyIdentityFile;
        };
        programs.ssh.extraConfig = lib.mkAfter yubikeyIdentityConfig;
      })
    ]
  );
}
