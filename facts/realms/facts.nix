{
  context,
  facts,
}:
let
  inherit (context) lanDomain;
  inherit (facts) nix-caches public-certificates public-keys;
  nixCaches = nix-caches;
  publicCertificates = public-certificates;
  publicKeys = public-keys;
in
{
  home = {
    build = {
      sshIdentityFile = "id_ed25519";
    };
    management = {
      manageNetworkIdentity = true;
      managePasswordSecrets = true;
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
      attic = {
        endpoint = "https://nix-cache.${lanDomain}";
      };
      internalPki.rootCaCertificate = publicCertificates.internal-pki.home-root-ca;
      flakehubCache.url = nixCaches.flakehub.url;
      nixCache = {
        substituters = [
          nixCaches.nixos.url
          nixCaches.home.defaultUrl
        ];
        trustedPublicKeys = [
          nixCaches.nixos.key
          nixCaches.home.key
        ];
      };
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
      managePasswordSecrets = false;
      sudoWheelNeedsPassword = true;
    };
    services.ups.credentialMode = "literal";
    trust.ssh.authorizedKeys = [
      publicKeys.users.jgwxhwdl4x
      publicKeys.users.jgwxhwdl4x-nix-builder
    ];
  };
}
