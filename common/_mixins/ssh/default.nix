{ ... }:
{
  services.openssh.enable = true;

  programs.ssh.knownHosts = {
    "beast" = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILC6++O8K1tm3RzwHD6igpTxDlJvUHIobfsNL2udZ/dm";
    };
  };
}
