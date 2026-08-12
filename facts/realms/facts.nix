{
  context,
  facts,
}:
let
  inherit (context) lanDomain;
  inherit (facts) public-keys;
  publicKeys = public-keys;
in
{
  home = {
    build = {
      sshIdentityFile = "id_ed25519";
    };
    management = {
      manageNetworkIdentity = true;
      sudoWheelNeedsPassword = false;
    };
    trust.ssh = {
      authorizedKeys = [
        publicKeys.users.mmini
        publicKeys.users.mair
        publicKeys.users.frame
        publicKeys.users.yubikey
        publicKeys.users.mair-secretive
      ];
      fleetBootHosts = true;
      tickets.trustedCaPublicKeys = [
        publicKeys.ssh-ca.fleet-user-ca
        publicKeys.users.yubikey
      ];
    };
    services = {
      observability = {
        loki = {
          writeUrl = "https://loki.${lanDomain}/loki/api/v1/push";
          mtls = true;
        };
        nodeExporter.mtls = true;
      };
      proxmox.oidcManagerHost = "prx1-lab";
      ups.credentialMode = "sops";
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
    services.ups.credentialMode = "literal";
    trust.ssh.authorizedKeys = [
      publicKeys.users.jgwxhwdl4x
      publicKeys.users.jgwxhwdl4x-nix-builder
    ];
  };
}
