{ }:
{
  home = {
    build = {
      sshIdentityFile = "id_ed25519";
    };
    management = {
      manageNetworkIdentity = true;
      sudoWheelNeedsPassword = false;
    };
  };

  work = {
    build = {
      sshIdentityFile = "jgwxhwdl4x-nix-builder";
    };
    management = {
      manageNetworkIdentity = false;
      sudoWheelNeedsPassword = true;
    };
  };
}
