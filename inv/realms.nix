{
  attic,
  backupFacts,
  lanDomain,
  nixCaches,
  readPublicKey,
  ssh,
  user,
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
      backups = backupFacts;
      internalPki = {
        providerHost = "pki";
        rootCaCertificate = ../public-keys/internal-pki/home-root-ca.crt;
        server = {
          port = 8443;
          # Fixed step-ca HTTP API route for the trusted root bundle.
          rootsPath = "/roots.pem";
        };
      };
      llm = {
        providerHost = "frame";
        serviceId = "ollama";
        models = [
          "gemma4:31b"
          "granite4:32b-a9b-h"
          "nemotron-cascade-2:30b"
          "nomic-embed-text"
          "qwen3-next:80b"
          "qwen3-vl:8b-instruct"
        ];
      };
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
        alertmanager.watchdogHosts = [ "frame" ];
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
      outboundMail = {
        host = "smtp.gmail.com";
        port = 587;
        username = user.emails.personal;
        fromAddress = user.emails.personal;
        replyToAddress = user.emails.personal;
      };
      publicIngress.host = "beast";
      proxmox.clusters.lab = {
        nodes = [
          "prx1-lab"
          "prx2-lab"
          "prx3-lab"
        ];
        defaultVmNode = "prx1-lab";
        oidcManagerHost = "prx1-lab";
        monitoringNode = "prx1-lab";
      };
      sso.providerHost = "pki";
      unifi = {
        baseUrl = "https://unifi";
        pollerHost = "fana";
        site = "default";
        syncHost = "pki";
      };
      uptimeRobot = {
        syncHost = "pki";
        maxMonitors = 10;
        excludedServiceIds = [
          # Degoog is an evaluation deployment covered by the fleet blackbox
          # probes.
          "goo"
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
    services = {
      proxmox.clusters.work = {
        nodes = [ "nvws" ];
        defaultVmNode = "nvws";
      };
      ups.credentialMode = "literal";
    };
    trust.ssh.authorizedKeys = ssh.authorizedKeysForRealm "work";
  };
}
