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
  hostInventory = import ../lib/inventory {
    inherit username;
    lib = pkgs.lib;
  };
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
  wireguardGatewaySshHost = wgHome.gateway.host;
  appPackages = import ./default.nix pkgs;

  fleetInventory = {
    aliases =
      builtins.listToAttrs (
        map (spec: {
          inherit (spec) name;
          value = spec.name;
        }) hostInventory.nixosHostSpecs
      )
      // pkgs.lib.mapAttrs (name: _: name) hostInventory.darwinHosts;
    darwin = pkgs.lib.mapAttrs (_: spec: {
      displayName = spec.name;
      isWork = spec.isWork or false;
      platform = spec.platform;
      runtimeHost = spec.name;
      sshHost = spec.name;
    }) hostInventory.darwinHosts;
    lanDnsServer = lan.gateway.address;
    lanDomain = lan.domain;
    nixos = builtins.listToAttrs (
      map (spec: {
        inherit (spec) name;
        value = {
          displayName = spec.name;
          isWork = spec.isWork or false;
          platform = spec.platform or "x86_64-linux";
          runtimeHost = spec.name;
          sshHost = spec.name;
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
      inherit (spec) name;
      value = spec.name;
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

  hbaFlash = pkgs.callPackage ./hba-flash {
    defaultSas3flashBundle = broadcomSas3flashP15;
    defaultFirmwareBundle = broadcomSas9305_24iP16_12;
  };
  issueInternalServiceCertPackage = appPackages.issue-internal-service-cert;
  issueObservabilityCertPackage = appPackages.issue-observability-cert;
  issueProxmoxExporterTokenPackage = appPackages.issue-proxmox-exporter-token;
  seerrRequestStoragePackage = appPackages.seerr-request-storage;
  seerrUpdateUserTagsPackage = appPackages.seerr-update-user-tags;
  pkiRotationPackage = pkgs.pki-rotation;
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
    issue-observability-cert = issueObservabilityCertPackage;
    issue-internal-service-cert = issueInternalServiceCertPackage;
    issue-proxmox-exporter-token = issueProxmoxExporterTokenPackage;
    seerr-request-storage = seerrRequestStoragePackage;
    seerr-update-user-tags = seerrUpdateUserTagsPackage;
    pki-rotation = pkiRotationPackage;
    reset-oidc = resetOidc;
    join-media-parts = pkgs.join-media-parts;
    hba-flash = hbaFlash;
    wg-home-client-config = wgHomeClientConfig;
  };
  apps = {
    deploy = mkApp "${deploy}/bin/deploy" "Apply fleet operations: host deploys (default) or disk provisioning (--disko).";
    vm = mkApp "${vm}/bin/vm" "Run a local NixOS VM for a nixosConfigurations host.";
    diff = mkApp "${diffConfig}/bin/diff" "Build and diff a NixOS or nix-darwin host configuration between two Git revisions.";
    "get-local-builders" =
      mkApp "${getLocalBuilders}/bin/get-local-builders" "Read local Nix builders from nix.conf or nix.machines.";
    "run-check-target" =
      mkApp "${runCheckTarget}/bin/run-check-target" "Build repository checks by name or as a complete set.";
    "issue-observability-cert" =
      mkApp "${issueObservabilityCertPackage}/bin/issue-observability-cert" "Issue internal PKI certs for Prometheus mTLS scrape endpoints and store them in host sops secrets.";
    "issue-internal-service-cert" =
      mkApp "${issueInternalServiceCertPackage}/bin/issue-internal-service-cert" "Issue internal PKI certs for internal HTTPS services and store them in host sops secrets.";
    "issue-proxmox-exporter-token" =
      mkApp "${issueProxmoxExporterTokenPackage}/bin/issue-proxmox-exporter-token" "Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets.";
    "seerr-request-storage" =
      mkApp "${seerrRequestStoragePackage}/bin/seerr-request-storage" "Report storage consumed by Radarr and Sonarr files attributable to Seerr requests.";
    "seerr-update-user-tags" =
      mkApp "${seerrUpdateUserTagsPackage}/bin/seerr-update-user-tags" "Backfill Seerr requester tags onto existing Radarr and Sonarr items.";
    "pki-rotation" =
      mkApp "${pkiRotationPackage}/bin/pki-rotation" "Inspect repo-managed internal PKI certificates and export rotation status.";
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
