{ username, ... }:
{
  users.mutableUsers = false;
  users.users.${username} = {
    extraGroups = ["wheel" "users"];
    group = username;
    isNormalUser = true;
    # TODO: separate authorizations between private and non-private VMs; read keys from files
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHt25mSiJLQjx2JECMuhTZEV6rlrOYk3CT2cUEdXAoYs ihrachyshka@ihrachyshka-mlt"
    ];
  };
  users.groups.${username} = {};
  security.sudo.wheelNeedsPassword = false;
  services.getty.autologinUser = username;
}
