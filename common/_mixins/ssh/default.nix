{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  sshKeys = builtins.filter (key: key ? sshPublicKey) (
    lib.concatMap builtins.attrValues (builtins.attrValues fleetInventory.yubikeys)
  );
  identityFor = key: {
    inherit (key) serial;
    public_key = builtins.readFile key.sshPublicKey;
    # Biometric models may need a touch before they need a PIN.
    pin_first = builtins.elem key.model [
      "YubiKey 5C Nano"
      "YubiKey 5C NFC"
    ];
  };
in
{
  imports = [
    ./access.nix
    ./known-hosts.nix
    ./pre-boot.nix
    ./ticket-server.nix
    ./tickets.nix
  ];

  environment.etc = lib.mkIf (config.host.ssh.credentials.backend == "yubikey") {
    "ssh/ssh-device-identities.json".text = builtins.toJSON (map identityFor sshKeys);
  };

  services.openssh.enable = true;
  services.openssh.extraConfig = ''
    AcceptEnv SOPS_KEYSERVICE SOPS_ENABLE_LOCAL_KEYSERVICE
  '';
}
