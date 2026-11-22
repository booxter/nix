{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "mmini-vm-ci";
  user = "_vm-runner";
  home = "/var/lib/${name}";
  tokenSecret = "github/vm_runner/token";
  prepareKeychain = pkgs.writeShellApplication {
    name = "prepare-vm-keychain.sh";
    text = ''
      umask 077
      directory="$HOME/Library/Keychains/tart"
      # macOS handles the login.keychain name specially, even in a subdirectory.
      keychain="$directory/tart.keychain-db"
      password_file="$directory/password"

      /bin/mkdir -p "$directory"
      if [[ ! -s "$password_file" ]]; then
        /usr/bin/uuidgen >"$password_file"
      fi
      password=$(<"$password_file")

      if [[ ! -f "$keychain" ]]; then
        /usr/bin/security create-keychain -p "$password" "$keychain"
      fi

      # Virtualization.framework needs an unlocked keychain without a GUI.
      # https://tart.run/faq/#headless-machines
      /usr/bin/security unlock-keychain -p "$password" "$keychain"
      /usr/bin/security default-keychain -s "$keychain"
      /usr/bin/security set-keychain-settings "$keychain"
    '';
  };
in
{
  ids.uids.${user} = 537;
  ids.gids.${user} = 537;

  users = {
    users.${user} = {
      uid = config.ids.uids.${user};
      gid = config.ids.gids.${user};
      inherit home;
      createHome = false;
      shell = "/bin/bash";
      description = "Tart VM integration runner";
    };
    groups.${user}.gid = config.ids.gids.${user};
    knownUsers = [ user ];
    knownGroups = [ user ];
  };

  system.tmpfiles.settings.vm-runner.${home}.d = {
    mode = "0700";
    inherit user;
    group = user;
  };

  services.github-runners.${name} = {
    enable = true;
    url = "https://github.com/booxter/nix-darwin-vm";
    tokenFile = config.sops.secrets.${tokenSecret}.path;
    inherit name user;
    group = user;
    ephemeral = true;
    extraLabels = [ "nix-vm-darwin" ];
    noDefaultLabels = true;
    replace = true;
    extraEnvironment = {
      # Registration and work directories are wiped between jobs; the home persists.
      HOME = home;
      ACTIONS_RUNNER_HOOK_JOB_STARTED = lib.getExe prepareKeychain;
    };
    serviceOverrides = {
      KeepAlive = lib.mkForce true;
      SessionCreate = true;
    };
  };

  services.github-runners.mmini-ci = {
    # The runner's HOME is cleared between jobs, so this keychain is disposable.
    extraEnvironment.CI_PREPARE_VM_KEYCHAIN = lib.getExe prepareKeychain;
    serviceOverrides.SessionCreate = true;
  };

  sops.secrets.${tokenSecret} = {
    mode = "0400";
    owner = user;
    group = user;
  };

  host.launchd.logging.locations.vm-runner = {
    directory = "/var/log/github-runners/${name}";
    collect = true;
    scope = "system";
  };
}
