{
  attic,
  lanDomain,
  nixCaches,
  readPublicKey,
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
      knownHosts.frame-initrd = {
        hostNames = [ "frame-initrd" ];
        publicKey = readPublicKey ../public-keys/hosts/frame-initrd.pub;
      };
      tickets.trustedCaPublicKeys = ssh.trustedCaPublicKeysForRealm "home";
    };
    services = {
      inherit attic;
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
        serverHost = "fana";
        blackbox.sourceHosts = [
          "fana"
          "beast"
          "frame"
        ];
        loki = {
          writeUrl = "https://loki.${lanDomain}/loki/api/v1/push";
          mtls = true;
        };
        nodeExporter.mtls = true;
      };
      publicIngress.host = "beast";
      proxmox.oidcManagerHost = "prx1-lab";
      remoteAccess = {
        appleRemoteManagement = true;
        vncClient = true;
        x11 = true;
      };
      unifi = {
        baseUrl = "https://unifi";
        site = "default";
        syncHost = "pki";
      };
      uptimeRobot = {
        syncHost = "pki";
        maxMonitors = 10;
        excludedServiceIds = [
          # Degoog and Paperless are evaluation deployments covered by the
          # fleet blackbox probes.
          "goo"
          "paperless"
          # PinePods has split-DNS, WAN, and systemd dependency alerts in
          # Prometheus.
          "pinepods"
        ];
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
