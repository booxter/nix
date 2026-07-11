{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.internalHttps;
  internalPkiRootCaPath = import ../../lib/home-internal-pki-root-ca.nix;
  # A local alias like `search` is served both as the single-label name and as
  # mDNS, for example `search` and `search.local`.
  localServerAliasesFor = aliases: aliases ++ builtins.map hostInventory.toLocalDnsName aliases;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
  # All hostnames that consume an nginx server_name on this machine. Example:
  # the Search service owns `search.home.arpa`, `search`, `search.local`, and
  # the public sibling vhost `search.ihar.dev`.
  serviceServerNames =
    service:
    [
      service.serverName
    ]
    ++ service.serverAliases
    ++ service.publicAliases;
  enabledServerNames = builtins.concatMap serviceServerNames (builtins.attrValues enabledServices);
  enabledProbeServices = lib.filterAttrs (_: service: service.probe.enable) enabledServices;
  servicesWithProbePortConflicts = lib.filterAttrs (
    _: service: service.probe.enable && service.probe.port == service.port
  ) enabledServices;
  enabledMtlsClients = lib.filterAttrs (_: client: client.enable) cfg.mtlsClients;
  secretAttrName = serviceName: "internal-https-${serviceName}";
  mtlsClientSecretAttrName = clientName: "internal-https-client-${clientName}";
  # Listener tuple shared by all surfaces for one service. Example: normal
  # service vhosts listen on :443 while probe-only vhosts listen on :9443.
  mkListen = service: port: [
    {
      addr = service.listenAddress;
      inherit port;
      ssl = true;
    }
  ];
  # TLS and optional client-cert verification common to every vhost surface for
  # a service. Example: `internal-https-search`, `search.ihar.dev`, and
  # `internal-https-search-probe` reuse the same certificate and mTLS policy.
  mkTlsVhost = serviceName: service: port: {
    extraConfig = lib.optionalString service.mtls.enable ''
      ssl_client_certificate ${service.mtls.trustedCaCertificate};
      ssl_verify_client on;
    '';
    listen = mkListen service port;
    sslCertificate = config.sops.secrets."${secretAttrName serviceName}-server-crt".path;
    sslCertificateKey = config.sops.secrets."${secretAttrName serviceName}-server-key".path;
    sslTrustedCertificate = internalPkiRootCaPath;
  };
  # The normal application proxy location for a service. Example: Search maps
  # `/` to SearXNG, while RomM maps `/api` to its API upstream.
  mkServiceLocations = service: {
    ${service.path} = {
      proxyPass = service.upstream;
      proxyWebsockets = service.proxyWebsockets;
      recommendedProxySettings = service.recommendedProxySettings;
      extraConfig = service.locationExtraConfig;
    };
  };
  # Builds a normal service surface on the service port. It is parameterized so
  # both the canonical internal host and public sibling hosts share one shape.
  # Examples: `search.home.arpa` and `search.ihar.dev` both proxy to SearXNG on
  # :443, but they are separate nginx vhosts.
  mkProxyVhost =
    {
      serviceName,
      service,
      serverName,
      serverAliases ? [ ],
    }:
    (mkTlsVhost serviceName service service.port)
    // {
      inherit serverName serverAliases;
      forceSSL = true;
      locations = mkServiceLocations service;
    };
  # Canonical internal service vhost. Example: `internal-https-search` serves
  # `search.home.arpa` plus internal aliases such as `search` and `search.local`.
  mkServiceVhost =
    serviceName: service:
    mkProxyVhost {
      inherit serviceName service;
      inherit (service) serverName serverAliases;
    };
  # Public sibling vhost for direct browser-facing names on the service host.
  # Example: `search.ihar.dev` gets the normal app and OAuth locations, but not
  # backend probe bypass locations.
  mkPublicAliasVhost =
    serviceName: service: publicAlias:
    mkProxyVhost {
      inherit serviceName service;
      serverName = publicAlias;
    };
  # Every public alias gets a sibling vhost keyed by that public hostname.
  # Example: `search.ihar.dev = mkPublicAliasVhost "search" search ...`.
  mkPublicAliasVhostsFor =
    serviceName: service:
    lib.genAttrs service.publicAliases (
      publicAlias: mkPublicAliasVhost serviceName service publicAlias
    );
  # Probe-only vhost on the probe port. Example:
  # `internal-https-search-probe` serves exact backend probe locations on
  # `https://search.home.arpa:9443/...`; its catch-all returns 404.
  mkProbeVhost =
    serviceName: service:
    (mkTlsVhost serviceName service service.probe.port)
    // {
      serverName = service.serverName;
      serverAliases = [ ];
      forceSSL = false;
      # Backend probes live on a separate HTTPS listener instead of the normal
      # service listener. Public ingress proxies to the normal service listener
      # using the internal server name, so host alias splitting alone would not
      # keep auth-bypass health endpoints off the WAN path.
      locations."/" = {
        return = "404";
        extraConfig = ''
          auth_request off;
        '';
      };
    };
in
{
  options.host.internalHttps.localAliases = lib.mkOption {
    type = with lib.types; listOf str;
    default = [ ];
    description = "Single-label local service names exported by enabled internal HTTPS services.";
  };

  options.host.internalHttps.mtlsClients = lib.mkOption {
    type =
      with lib.types;
      attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "internal HTTPS mTLS client identity";

              secretPrefix = lib.mkOption {
                type = str;
                default = "internal_https/clients/${name}";
                description = "SOPS key prefix containing client_crt_unencrypted and client_key for this client identity.";
              };

              commonName = lib.mkOption {
                type = str;
                default = "${name}.${config.host.dnsName}";
                description = "Leaf certificate common name to issue for this client identity.";
              };

              sans = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Optional SANs for this client certificate.";
              };

              owner = lib.mkOption {
                type = str;
                default = "root";
                description = "Owner for generated client certificate and key secret files.";
              };

              group = lib.mkOption {
                type = str;
                default = "root";
                description = "Group for generated client certificate and key secret files.";
              };

              mode = lib.mkOption {
                type = str;
                default = "0400";
                description = "Mode for generated client certificate and key secret files.";
              };

              restartUnits = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Systemd units restarted when this client certificate changes.";
              };
            };
          }
        )
      );
    default = { };
    description = "Internal HTTPS mTLS client identities used by services on this host.";
  };

  options.host.internalHttps.services = lib.mkOption {
    type =
      with lib.types;
      attrsOf (
        submodule (
          { name, config, ... }:
          {
            config.serverAliases = lib.mkBefore (localServerAliasesFor config.localAliases);

            options = {
              enable = lib.mkEnableOption "internal HTTPS service";

              serverName = lib.mkOption {
                type = str;
                default = "${name}.${hostInventory.site.lan.domain}";
                description = "DNS name presented by the internal HTTPS vhost.";
              };

              serverAliases = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
                description = "Additional internal hostnames served by the canonical internal HTTPS vhost.";
              };

              publicAliases = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
                description = "Browser-facing hostnames served by sibling HTTPS vhosts with the same upstream and certificate.";
              };

              sans = lib.mkOption {
                type = with lib.types; listOf str;
                default = lib.unique (
                  [
                    name
                    config.serverName
                  ]
                  ++ config.serverAliases
                  ++ config.publicAliases
                );
                description = "DNS SANs to include when issuing this service certificate.";
              };

              localAliases = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ name ];
                description = "Single-label local service names to serve directly and as .local mDNS names.";
              };

              listenAddress = lib.mkOption {
                type = str;
                default = "0.0.0.0";
                description = "Address for the internal HTTPS vhost to bind.";
              };

              port = lib.mkOption {
                type = port;
                default = 443;
                description = "Port for the internal HTTPS vhost.";
              };

              path = lib.mkOption {
                type = str;
                default = "/";
                description = "Path to expose through the HTTPS reverse proxy.";
              };

              upstream = lib.mkOption {
                type = str;
                description = "Loopback or private upstream URL for the internal HTTPS service.";
              };

              openFirewall = lib.mkOption {
                type = bool;
                default = true;
                description = "Whether to open the firewall for the internal HTTPS service.";
              };

              proxyWebsockets = lib.mkOption {
                type = bool;
                default = true;
                description = "Whether to enable websocket proxy headers.";
              };

              recommendedProxySettings = lib.mkOption {
                type = bool;
                default = true;
                description = "Whether to apply NixOS nginx recommended proxy headers automatically.";
              };

              secretPrefix = lib.mkOption {
                type = str;
                default = "internal_https/${name}";
                description = "SOPS key prefix containing server_crt_unencrypted and server_key for this service.";
              };

              locationExtraConfig = lib.mkOption {
                type = lines;
                default = "";
                description = "Extra nginx location config for this service.";
              };

              mtls = {
                enable = lib.mkEnableOption "client certificate authentication for this internal HTTPS service";

                trustedCaCertificate = lib.mkOption {
                  type = path;
                  default = internalPkiRootCaPath;
                  description = "CA certificate bundle trusted for inbound client certificate verification.";
                };
              };

              probe = {
                enable = lib.mkEnableOption "probe-only internal HTTPS listener";

                port = lib.mkOption {
                  type = port;
                  default = 9443;
                  description = "HTTPS port for exact backend probe locations; no catch-all upstream is exposed on this listener.";
                };
              };
            };
          }
        )
      );
    default = { };
    description = "Internal HTTPS services fronted by nginx and backed by the internal PKI.";
  };

  config = lib.mkIf (enabledServices != { } || enabledMtlsClients != { }) {
    host.internalHttps.localAliases = lib.unique (
      builtins.concatMap (service: service.localAliases) (builtins.attrValues enabledServices)
    );

    assertions = lib.optionals (enabledServices != { }) [
      {
        assertion =
          (builtins.length enabledServerNames) == (builtins.length (lib.unique enabledServerNames));
        message = "host.internalHttps.services must not reuse the same serverName, serverAlias, or publicAlias on one host.";
      }
      {
        assertion = servicesWithProbePortConflicts == { };
        message = "host.internalHttps.services probe listeners must use a port distinct from the normal service port. Offenders: ${lib.concatStringsSep ", " (builtins.attrNames servicesWithProbePortConflicts)}";
      }
    ];

    sops.secrets =
      lib.mapAttrs' (
        serviceName: service:
        lib.nameValuePair "${secretAttrName serviceName}-server-crt" {
          key = "${service.secretPrefix}/server_crt_unencrypted";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) enabledServices
      // lib.mapAttrs' (
        serviceName: service:
        lib.nameValuePair "${secretAttrName serviceName}-server-key" {
          key = "${service.secretPrefix}/server_key";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) enabledServices
      // lib.mapAttrs' (
        clientName: client:
        lib.nameValuePair "${mtlsClientSecretAttrName clientName}-crt" {
          key = "${client.secretPrefix}/client_crt_unencrypted";
          owner = client.owner;
          group = client.group;
          mode = client.mode;
          restartUnits = client.restartUnits;
        }
      ) enabledMtlsClients
      // lib.mapAttrs' (
        clientName: client:
        lib.nameValuePair "${mtlsClientSecretAttrName clientName}-key" {
          key = "${client.secretPrefix}/client_key";
          owner = client.owner;
          group = client.group;
          mode = client.mode;
          restartUnits = client.restartUnits;
        }
      ) enabledMtlsClients;

    services.nginx = lib.mkIf (enabledServices != { }) {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts =
        lib.mapAttrs' (
          serviceName: service:
          lib.nameValuePair "internal-https-${serviceName}" (mkServiceVhost serviceName service)
        ) enabledServices
        // lib.concatMapAttrs mkPublicAliasVhostsFor enabledServices
        // lib.mapAttrs' (
          serviceName: service:
          lib.nameValuePair "internal-https-${serviceName}-probe" (mkProbeVhost serviceName service)
        ) enabledProbeServices;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf (enabledServices != { }) (
      lib.unique (
        builtins.concatMap (
          service:
          lib.optionals service.openFirewall [
            80
            service.port
          ]
          ++ lib.optionals (service.openFirewall && service.probe.enable) [
            service.probe.port
          ]
        ) (builtins.attrValues enabledServices)
      )
    );

    systemd.services.nginx = lib.mkIf (enabledServices != { }) {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
