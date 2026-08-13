{
  facts,
  outputs,
  pkgs,
}:
let
  fleetConfiguration = builtins.head (builtins.attrValues outputs.nixosConfigurations);
  lan = fleetConfiguration.config.host.site.lan;
  wgHome = fleetConfiguration.config.host.wireguard.networks.home;
  appPackages = import ./packages.nix pkgs;

  fleetFacts = {
    aliases =
      pkgs.lib.mapAttrs (name: _: name) facts.hosts.nixos
      // pkgs.lib.mapAttrs (name: _: name) facts.hosts.darwin;
    darwin = pkgs.lib.mapAttrs (_: spec: {
      displayName = spec.name;
      inherit (spec) realm;
      platform = "aarch64-darwin";
      runtimeHost = spec.name;
      sshHost = spec.name;
    }) facts.hosts.darwin;
    lanDnsServer = lan.gateway.address;
    lanDomain = fleetConfiguration.config.host.network.lanDomain;
    nixos = pkgs.lib.mapAttrs (_: spec: {
      displayName = spec.name;
      inherit (spec) realm;
      platform = "x86_64-linux";
      runtimeHost = spec.name;
      sshHost = spec.name;
    }) facts.hosts.nixos;
  };
  wireguardHome = {
    subnet = wgHome.cidr;
    inherit (wgHome.clientPolicy) dns;
    endpoint = "${wgHome.server.publicEndpoint}:${toString wgHome.server.listenPort}";
    allowedIps = wgHome.clientPolicy.allowedIPs;
    peers = pkgs.lib.mapAttrs (_name: peer: peer.address) wgHome.peers;
    gatewaySshHost = wgHome.server.host;
  };
  vmTargets = pkgs.lib.mapAttrs (name: _: name) facts.hosts.nixos;
  fleetTools = pkgs.callPackage ./fleet-tools {
    inherit fleetFacts vmTargets wireguardHome;
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
  resetOidc = pkgs.callPackage ../nixos/_mixins/sso/provider/pkgs/kanidm-tools { };
  wgHomeClientConfig = fleetTools;
in
{
  packages = {
    inherit deploy vm;
    diff = diffConfig;
    fleet-tools = fleetTools;
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
}
