{
  fleetInventory,
  outputs,
  pkgs,
}:
let
  fleetConfiguration = builtins.head (builtins.attrValues outputs.nixosConfigurations);
  lan = fleetConfiguration.config.host.site.lan;
  wgHome = outputs.nixosConfigurations.gw.config.host.wireguard.networks.home;
  mkFleetHost = system: name: configuration: {
    displayName = name;
    inherit system;
    realm = configuration.config.host.realm;
    runtimeHost = name;
    sshHost = name;
  };
  darwinHosts = pkgs.lib.mapAttrs (mkFleetHost "aarch64-darwin") outputs.darwinConfigurations;
  nixosHosts = pkgs.lib.mapAttrs (mkFleetHost "x86_64-linux") outputs.nixosConfigurations;
  fleetHosts = nixosHosts // darwinHosts;
  realmsByHost = pkgs.lib.mapAttrs (_: host: host.realm) fleetInventory.hosts;
  tokenHosts = pkgs.lib.mapAttrs (_: host: { inherit (host) realm system; }) fleetHosts;
  appPackages = import ./packages.nix {
    fleetHosts = tokenHosts;
    inherit pkgs realmsByHost;
  };

  toolInventory = {
    aliases =
      pkgs.lib.mapAttrs (name: _: name) outputs.nixosConfigurations
      // pkgs.lib.mapAttrs (name: _: name) outputs.darwinConfigurations;
    darwin = pkgs.lib.mapAttrs (
      _: host: (removeAttrs host [ "system" ]) // { platform = host.system; }
    ) darwinHosts;
    lanDnsServer = lan.gateway.address;
    lanDomain = fleetConfiguration.config.host.network.lanDomain;
    nixos = pkgs.lib.mapAttrs (
      _: host: (removeAttrs host [ "system" ]) // { platform = host.system; }
    ) nixosHosts;
  };
  wireguardHome = {
    subnet = wgHome.cidr;
    inherit (wgHome.clientPolicy) dns;
    endpoint = "${wgHome.server.publicEndpoint}:${toString wgHome.server.listenPort}";
    allowedIps = wgHome.clientPolicy.allowedIPs;
    peers = pkgs.lib.mapAttrs (_name: peer: peer.address) wgHome.peers;
    gatewaySshHost = wgHome.server.host;
  };
  vmTargets = pkgs.lib.mapAttrs (name: _: name) outputs.nixosConfigurations;
  fleetTools = pkgs.callPackage ./fleet-tools {
    fleetInventory = toolInventory;
    inherit vmTargets wireguardHome;
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
  pkiRotationPackage = pkgs.callPackage ../pkgs/pki-rotation {
    atomicFileWrites = pkgs.atomic-file-writes;
    gitCommandRunner = pkgs.git-command-runner;
    pkiCertificates = appPackages.issue-internal-service-cert;
    sopsTools = appPackages.sops-tools;
  };
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
