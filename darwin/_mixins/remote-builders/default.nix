{ pkgs, username, ... }:
{
  programs.ssh = {
    knownHosts = {
      "mmini" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8s28KbVXwhV4K5c5WDd6adK5wSSjyT7EWLqkF1VhQf";
      };
      "mair" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICHqTUyXOeL1O4JPIDxf8EzUzgKLmkW4C2g9EezZMivL";
      };
    };
    extraConfig =
      let
        identityFile = "/Users/${username}/.ssh/id_ed25519";
        user = "ihrachyshka";
      in
      ''
        Host mmini
          Hostname mmini
          IdentityFile ${identityFile}
          User ${user}

        Host mair
          Hostname mair
          IdentityFile ${identityFile}
          User ${user}
      '';
  };
  environment.systemPackages = [ pkgs.openssh_gssapi ];
}
