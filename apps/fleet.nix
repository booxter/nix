{
  pkgs,
  username ? "ihrachyshka",
}:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
  hostInventory = import ../lib/inventory.nix {
    inherit username;
    lib = pkgs.lib;
  };
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
  wireguardGatewaySshHost = hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.gw;
  appPackages = import ./default.nix pkgs;

  fleetInventory = {
    aliases =
      builtins.listToAttrs (
        map (spec: {
          name = hostInventory.toNixosConfigName spec;
          value = hostInventory.toNixosConfigName spec;
        }) hostInventory.nixosHostSpecs
      )
      // pkgs.lib.foldlAttrs (
        aliases: name: config:
        let
          hostname = config.hostname or name;
        in
        aliases // { ${name} = name; } // pkgs.lib.optionalAttrs (hostname != name) { ${hostname} = name; }
      ) { } hostInventory.darwinHosts;
    darwin = pkgs.lib.mapAttrs (name: config: {
      displayName = name;
      isWork = config.isWork or false;
      platform = config.platform;
      runtimeHost = config.hostname or name;
      sshHost = config.hostname or name;
    }) hostInventory.darwinHosts;
    lanDnsServer = lan.gateway.address;
    lanDomain = lan.domain;
    nixos = builtins.listToAttrs (
      map (spec: {
        name = hostInventory.toNixosConfigName spec;
        value = {
          displayName = hostInventory.toNixosConfigName spec;
          isWork = spec.isWork or false;
          platform = spec.platform or "x86_64-linux";
          runtimeHost = hostInventory.toNixosRuntimeHostName spec;
          sshHost = hostInventory.toNixosShortDnsName spec;
        };
      }) hostInventory.nixosHostSpecs
    );
  };
  wireguardHome = {
    subnet = wgHome.cidr;
    dns = [
      lan.gateway.address
      lan.domain
    ];
    endpoint = "${wgHome.gateway.publicEndpoint}:${toString wgHome.gateway.listenPort}";
    allowedIps = [
      wgHome.cidr
      lan.cidr
    ];
    peers = pkgs.lib.mapAttrs (_name: peer: peer.address) wgHome.peers;
    gatewaySshHost = wireguardGatewaySshHost;
  };
  vmTargets = builtins.listToAttrs (
    map (spec: {
      name = spec.name;
      value = hostInventory.toNixosConfigName spec;
    }) hostInventory.nixosHostSpecs
  );
  fleetTools = pkgs.callPackage ./fleet-tools {
    inherit fleetInventory vmTargets wireguardHome;
  };

  broadcomSas3flashP15 = pkgs.fetchzip {
    pname = "broadcom-sas3flash";
    version = "p15";
    url = "https://docs.broadcom.com/docs-and-downloads/host-bus-adapters/host-bus-adapters-common-files/sas_sata_12g_p15/SAS3FLASH_P15.zip";
    hash = "sha256-60NPMEhHR4Q10TJ5yMcsa/NR3fwvN3piL6g387EC93k=";
    stripRoot = false;
    meta = with pkgs.lib; {
      description = "Broadcom SAS3FLASH utility bundle for 12Gb SAS/SATA HBAs";
      homepage = "https://docs.broadcom.com/";
      license = licenses.unfreeRedistributableFirmware;
      sourceProvenance = [ sourceTypes.binaryNativeCode ];
      platforms = platforms.all;
    };
  };

  broadcomSas9305_24iP16_12 = pkgs.fetchzip {
    pname = "broadcom-sas9305-24i-firmware";
    version = "16.00.12.00";
    url = "https://docs.broadcom.com/docs-and-downloads/host-bus-adapters/host-bus-adapters-common-files/sas_sata_12g_p16.12_cutlass_point_release/9305_24i_Pkg_P16.12_IT_FW_BIOS_for_MSDOS_Windows.zip";
    hash = "sha256-CcBdBTwONvZ22QmcKC7aUyJCbAkYWQxEgoWSsC+3ZoY=";
    stripRoot = false;
    meta = with pkgs.lib; {
      description = "Broadcom SAS9305-24i IT firmware bundle";
      homepage = "https://docs.broadcom.com/";
      license = licenses.unfreeRedistributableFirmware;
      sourceProvenance = [ sourceTypes.binaryNativeCode ];
      platforms = platforms.all;
    };
  };

  getHosts = fleetTools;

  deploy = fleetTools;

  vm = fleetTools;

  diffConfig = fleetTools;

  getLocalBuilders = fleetTools;

  runCheckTarget = fleetTools;

  hbaFlash = pkgs.writeShellApplication {
    name = "hba-flash";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      gnused
      openssh
      unzip
      util-linux
    ];
    text = ''
      export HBA_FLASH_DEFAULT_SAS3FLASH_BUNDLE="${broadcomSas3flashP15}"
      export HBA_FLASH_DEFAULT_FIRMWARE_BUNDLE="${broadcomSas9305_24iP16_12}"
    ''
    + builtins.readFile ../apps/hba-flash.sh;
  };
  issueInternalServiceCertPackage = appPackages.issue-internal-service-cert;
  issueObservabilityCertPackage = appPackages.issue-observability-cert;
  issueProxmoxExporterTokenPackage = appPackages.issue-proxmox-exporter-token;
  seerrRequestStoragePackage = appPackages.seerr-request-storage;
  seerrUpdateUserTagsPackage = appPackages.seerr-update-user-tags;
  pkiRotationPackage = pkgs.pki-rotation;
  issueObservabilityCertApp = pkgs.writeShellApplication {
    name = "issue-observability-cert-app";
    text = ''
      exec ${issueObservabilityCertPackage}/bin/issue-observability-cert "$@"
    '';
  };
  issueInternalServiceCertApp = pkgs.writeShellApplication {
    name = "issue-internal-service-cert-app";
    text = ''
      export ISSUE_INTERNAL_SERVICE_CERT_UNIFI_COMMON_NAME=${pkgs.lib.escapeShellArg "unifi.${lan.domain}"}
      export ISSUE_INTERNAL_SERVICE_CERT_UNIFI_SANS_JSON=${
        pkgs.lib.escapeShellArg (
          builtins.toJSON [
            "unifi.${lan.domain}"
            "unifi"
          ]
        )
      }
      export ISSUE_INTERNAL_SERVICE_CERT_UNIFI_GATEWAY_IP=${pkgs.lib.escapeShellArg lan.gateway.address}
      exec ${issueInternalServiceCertPackage}/bin/issue-internal-service-cert "$@"
    '';
  };
  issueProxmoxExporterTokenApp = pkgs.writeShellApplication {
    name = "issue-proxmox-exporter-token-app";
    text = ''
      exec ${issueProxmoxExporterTokenPackage}/bin/issue-proxmox-exporter-token "$@"
    '';
  };
  pkiRotationApp = pkgs.writeShellApplication {
    name = "pki-rotation-app";
    text = ''
      export PKI_ROTATION_REPO_ROOT="${../.}"
      exec ${pkiRotationPackage}/bin/pki-rotation "$@"
    '';
  };
  resetOidc = pkgs.callPackage ../nixos/pki/pkgs/kanidm-tools { };
  wgHomeClientConfig = fleetTools;
in
{
  packages = {
    inherit deploy vm;
    diff = diffConfig;
    fleet-tools = fleetTools;
    get-local-builders = getLocalBuilders;
    run-check-target = runCheckTarget;
    get-hosts = getHosts;
    issue-observability-cert = issueObservabilityCertApp;
    issue-internal-service-cert = issueInternalServiceCertApp;
    issue-proxmox-exporter-token = issueProxmoxExporterTokenApp;
    seerr-request-storage = seerrRequestStoragePackage;
    seerr-update-user-tags = seerrUpdateUserTagsPackage;
    pki-rotation = pkiRotationApp;
    reset-oidc = resetOidc;
    join-media-parts = pkgs.join-media-parts;
    hba-flash = hbaFlash;
    wg-home-client-config = wgHomeClientConfig;
  };
  apps = {
    deploy = mkApp "${deploy}/bin/deploy" "Apply fleet operations: host deploys (default) or disk provisioning (--disko).";
    "fleet-deploy-remote" =
      mkApp "${fleetTools}/bin/fleet-deploy-remote" "Run the internal target-side fleet deployment helper.";
    vm = mkApp "${vm}/bin/vm" "Run a local NixOS VM for a nixosConfigurations host.";
    diff = mkApp "${diffConfig}/bin/diff" "Build and diff a NixOS or nix-darwin host configuration between two Git revisions.";
    "get-local-builders" =
      mkApp "${getLocalBuilders}/bin/get-local-builders" "Read local Nix builders from nix.conf or nix.machines.";
    "run-check-target" =
      mkApp "${runCheckTarget}/bin/run-check-target" "Build repository checks by name or as a complete set.";
    "issue-observability-cert" =
      mkApp "${issueObservabilityCertApp}/bin/issue-observability-cert-app" "Issue internal PKI certs for Prometheus mTLS scrape endpoints and store them in host sops secrets.";
    "issue-internal-service-cert" =
      mkApp "${issueInternalServiceCertApp}/bin/issue-internal-service-cert-app" "Issue internal PKI certs for internal HTTPS services and store them in host sops secrets.";
    "issue-proxmox-exporter-token" =
      mkApp "${issueProxmoxExporterTokenApp}/bin/issue-proxmox-exporter-token-app" "Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets.";
    "seerr-request-storage" =
      mkApp "${seerrRequestStoragePackage}/bin/seerr-request-storage" "Report storage consumed by Radarr and Sonarr files attributable to Seerr requests.";
    "seerr-update-user-tags" =
      mkApp "${seerrUpdateUserTagsPackage}/bin/seerr-update-user-tags" "Backfill Seerr requester tags onto existing Radarr and Sonarr items.";
    "pki-rotation" =
      mkApp "${pkiRotationApp}/bin/pki-rotation-app" "Inspect repo-managed internal PKI certificates and export rotation status.";
    "reset-oidc" =
      mkApp "${resetOidc}/bin/reset-oidc" "Send a Kanidm OIDC credential reset email through pki.";
    "join-media-parts" =
      mkApp "${pkgs.join-media-parts}/bin/join-media-parts" "Join ordered TS/MP4/MKV media parts into one file.";
    "hba-flash" =
      mkApp "${hbaFlash}/bin/hba-flash" "Preflight and flash the Broadcom/LSI HBA on beast using pinned Broadcom bundles by default.";
    "wg-home-client-config" =
      mkApp "${wgHomeClientConfig}/bin/wg-home-client-config" "Generate a home WireGuard client config from fleet topology.";
  };
}
