{
  lanDomain,
  nixCaches,
  readPublicKey,
}:
{
  home = {
    build = {
      includeUnscopedCiTargets = true;
      pools = [
        "community"
        "personal"
      ];
    };
    secretDomain = "main";
    trust.ssh = {
      authorizedKeys = [
        (readPublicKey ../public-keys/users/mmini.pub)
        (readPublicKey ../public-keys/users/mair.pub)
        (readPublicKey ../public-keys/users/frame.pub)
        (readPublicKey ../public-keys/yubikey.pub)
        (readPublicKey ../public-keys/mair-secretive.pub)
      ];
      fleetBootHosts = true;
      tickets.trustedCaPublicKeys = [
        (readPublicKey ../public-keys/ssh-ca/fleet-user-ca.pub)
        (readPublicKey ../public-keys/yubikey.pub)
      ];
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
    };
  };

  work = {
    build.pools = [ "work" ];
    secretDomain = "work";
    services = { };
    trust.ssh.authorizedKeys = [
      (readPublicKey ../public-keys/users/jgwxhwdl4x.pub)
      (readPublicKey ../public-keys/users/jgwxhwdl4x-nix-builder.pub)
    ];
  };
}
