{ pkgs, username, ... }: {
  programs.ssh = {
    knownHosts = {
      "aarch64-build-box.nix-community.org" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG9uyfhyli+BRtk64y+niqtb+sKquRGGZ87f4YRc8EE1";
      };
      "build-box.nix-community.org" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIElIQ54qAy7Dh63rBudYKdbzJHrrbrrMXLYl7Pkmk88H";
      };
      "darwin-build-box.nix-community.org" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKMHhlcn7fUpUuiOFeIhDqBzBNFsbNqq+NpzuGX3e6zv";
      };
    };
    extraConfig = let
      identityFile = "/Users/${username}/.ssh/id_ed25519";
      user = "booxter";
    in ''
      Host darwin-builder
        Hostname darwin-build-box.nix-community.org
        IdentityFile ${identityFile}
        User ${user}

      Host linux-builder
        Hostname aarch64-build-box.nix-community.org
        IdentityFile ${identityFile}
        User ${user}

      Host linux-x86-builder
        Hostname build-box.nix-community.org
        IdentityFile ${identityFile}
        User ${user}
    '';
  };
  environment.systemPackages = [ pkgs.openssh ];
}
