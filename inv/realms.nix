{
  lanDomain,
  nixCaches,
  ssh,
}:
{
  home = {
    build.pools = [
      "community"
      "personal"
    ];
    secretDomain = "main";
    management = {
      manageNetworkIdentity = true;
      managePasswordSecrets = true;
      sudoWheelNeedsPassword = false;
    };
    trust.ssh = {
      authorizedKeys = ssh.authorizedKeysForRealm "home";
      fleetBootHosts = true;
      tickets.trustedCaPublicKeys = ssh.trustedCaPublicKeysForRealm "home";
    };
    services = {
      attic = {
        cacheName = "local";
        endpoint = "https://nix-cache.${lanDomain}";
      };
      internalPki.rootCaCertificate = ../public-keys/internal-pki/home-root-ca.crt;
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
      remoteAccess = {
        appleRemoteManagement = true;
        vncClient = true;
        x11 = true;
      };
      ups.credentialMode = "sops";
    };
  };

  work = {
    build.pools = [ "work" ];
    secretDomain = "work";
    management = {
      manageNetworkIdentity = false;
      managePasswordSecrets = false;
      sudoWheelNeedsPassword = true;
    };
    services.ups.credentialMode = "literal";
    trust.ssh.authorizedKeys = ssh.authorizedKeysForRealm "work";
  };
}
