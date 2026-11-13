{
  config,
  lib,
  osConfig,
  pkgs,
  sshKeys,
  ...
}:
let
  backend = osConfig.host.ssh.credentials.backend;
  enabled = config.host.hm.env.roles.developer;
  useSecretive = backend == "secretive";
  useYubikey = backend == "yubikey";
  secretiveSocket = "${config.home.homeDirectory}/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh";
  secretiveAuthSockInit = ''
    if [ -z "$SSH_AUTH_SOCK" -o -z "$SSH_CONNECTION" ]; then
      export SSH_AUTH_SOCK="${secretiveSocket}"
    fi
  '';
  yubikeyIdentityFiles = map (
    name: "${config.home.homeDirectory}/.ssh/${name}"
  ) osConfig.host.ssh.credentials.yubikey.identityFiles;
  yubikeyIdentityConfig = ''
    Match exec "test -z \"$SSH_CONNECTION\""
    ${lib.concatMapStrings (path: "  IdentityFile ${path}\n") yubikeyIdentityFiles}
      IdentitiesOnly yes

    Match exec "test -n \"$SSH_CONNECTION\" && test -S \"$SSH_AUTH_SOCK\""
      IdentitiesOnly no

    Host *
  '';
  signingKey = pkgs.callPackage ./pkgs/git-hardware-signing-key.nix {
    approvedKeysFile = pkgs.writeText "hardware-signing-keys" (
      lib.concatMapStrings (key: key + "\n") sshKeys.hardware
    );
    localIdentityFiles = lib.optionals useYubikey yubikeyIdentityFiles;
  };
in
{
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        programs.ssh.settings."*".AddKeysToAgent = if useSecretive || useYubikey then "no" else "yes";
      }
      (lib.mkIf (useSecretive || useYubikey) {
        programs.git.settings.gpg.ssh.defaultKeyCommand = lib.getExe signingKey;
      })
      (lib.mkIf useSecretive {
        home.file.".ssh/secretive.pub".text = osConfig.host.ssh.credentials.secretive.publicKey + "\n";
        programs.bash = {
          profileExtra = lib.mkOrder 900 secretiveAuthSockInit;
          initExtra = lib.mkOrder 900 secretiveAuthSockInit;
        };
        programs.zsh.envExtra = lib.mkOrder 900 secretiveAuthSockInit;
      })
      (lib.mkIf useYubikey {
        programs.ssh.extraConfig = lib.mkAfter yubikeyIdentityConfig;
      })
    ]
  );
}
