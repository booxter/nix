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
  mkBatsCheck =
    {
      environment ? { },
      nativeCheckInputs ? [ ],
      test,
      targetEnvironmentVariable ? null,
    }:
    {
      derivationArgs = {
        doCheck = true;
        inherit nativeCheckInputs;
      };
      checkPhase = ''
        runHook preCheck
        ${pkgs.lib.getExe pkgs.bash} -n "$target"
        ${pkgs.lib.getExe pkgs.shellcheck} "$target"
        ${pkgs.lib.concatStringsSep "\n" (
          pkgs.lib.mapAttrsToList (
            name: value: "export ${name}=${pkgs.lib.escapeShellArg (toString value)}"
          ) environment
        )}
        ${pkgs.lib.optionalString (targetEnvironmentVariable != null) ''
          export ${targetEnvironmentVariable}="$target"
        ''}
        cd ${../.}
        ${pkgs.lib.getExe pkgs.bats} --print-output-on-failure ${test}
        runHook postCheck
      '';
    };

  hostInventory = import ../lib/inventory.nix {
    inherit username;
    lib = pkgs.lib;
  };
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
  wireguardGatewaySshHost = hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.gw;
  appPackages = import ./default.nix pkgs;

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

  getHosts = pkgs.writeShellApplication {
    name = "get-hosts";
    runtimeInputs = [ pkgs.nix ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../.}/apps/get-hosts.sh "$@"
    '';
    inherit
      (mkBatsCheck {
        test = ./get-hosts.bats;
        targetEnvironmentVariable = "GET_HOSTS_BIN";
        nativeCheckInputs = [ pkgs.jq ];
      })
      derivationArgs
      checkPhase
      ;
  };

  deploy = pkgs.writeShellApplication {
    name = "deploy";
    runtimeInputs =
      (with pkgs; [
        bind
        fzf
        git
        jq
        nix
        openssh
      ])
      ++ [ getHosts ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage:
        deploy [fleet deploy args]
        deploy --disko <host> <device>

      GitHub branch deployments merge the latest origin/master by default.
      Pass --no-merge to deploy the selected branch exactly as published.
      Pass --no-inhibit to bypass NixOS activation checks explicitly.

      Examples:
        deploy
        deploy -A --select
        deploy --branch ci/flake-update --boot srvarr
        deploy --branch ci/flake-update --no-merge srvarr
        deploy --no-inhibit beast
        deploy --branch dhcp-unifi --test beast
        deploy --local mair
        deploy --disko frame /dev/sdX
      EOF
      }

      if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "$#" -gt 0 ] && [ "$1" = "--disko" ]; then
        shift

        if [ "$#" -ne 2 ]; then
          usage >&2
          exit 1
        fi

        host="$1"
        device="$2"
        disko_cmd=(
          nix
          --extra-experimental-features "nix-command flakes"
          run
          -L
          --show-trace
          "${../.}#disko-install"
          --
          --flake "${../.}#''${host}"
          --disk main
          "''${device}"
        )

        if [ "''${EUID}" -eq 0 ]; then
          exec "''${disko_cmd[@]}"
        fi
        exec sudo "''${disko_cmd[@]}"
      fi

      export UPDATE_MACHINES_GET_HOSTS_BIN=${pkgs.lib.getExe getHosts}
      exec ${pkgs.bash}/bin/bash ${../.}/apps/update-machines.sh "$@"
    '';
    inherit
      (mkBatsCheck {
        test = ./update-machines.bats;
        environment = {
          FLEET_TEST_REPO_ROOT = "${../.}";
          UPDATE_MACHINES_BIN = "${../.}/apps/update-machines.sh";
        };
        nativeCheckInputs = with pkgs; [
          fzf
          git
          jq
          openssh
        ];
      })
      derivationArgs
      checkPhase
      ;
  };

  vm = pkgs.writeShellApplication {
    name = "vm";
    runtimeInputs = with pkgs; [
      jq
      nix
    ];
    text = ''
      export VM_REPO_ROOT="${../.}"
      exec ${pkgs.bash}/bin/bash ${../apps/vm.sh} "$@"
    '';
    inherit
      (mkBatsCheck {
        test = ./vm.bats;
        environment.VM_BIN = "${./vm.sh}";
        nativeCheckInputs = [ pkgs.jq ];
      })
      derivationArgs
      checkPhase
      ;
  };

  diffConfig = pkgs.writeShellApplication {
    name = "diff";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      dix
      findutils
      git
      gnugrep
      gnused
      jq
      nh
      nix
    ];
    text = ''
      export DIFF_CONFIG_PROGRAM_NAME=diff
      exec ${pkgs.bash}/bin/bash ${../apps/diff-config.sh} "$@"
    '';
    inherit
      (mkBatsCheck {
        test = ./diff-config.bats;
        environment.DIFF_CONFIG_BIN = "${./diff-config.sh}";
        nativeCheckInputs = with pkgs; [
          git
          jq
        ];
      })
      derivationArgs
      checkPhase
      ;
  };

  getLocalBuilders = pkgs.writeShellApplication {
    name = "get-local-builders";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../apps/get-local-builders.sh} "$@"
    '';
    inherit
      (mkBatsCheck {
        test = ./get-local-builders.bats;
        environment.GET_LOCAL_BUILDERS_BIN = "${./get-local-builders.sh}";
      })
      derivationArgs
      checkPhase
      ;
  };

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
  resetOidc = pkgs.callPackage ../nixos/pki/pkgs/reset-oidc { };
  wgHomeClientConfig = pkgs.writeShellApplication {
    name = "wg-home-client-config";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      set -euo pipefail

      WG_HOME_CIDR='${wgHome.cidr}'
      WG_HOME_DNS='${lan.gateway.address}, ${lan.domain}'
      WG_HOME_ENDPOINT='${wgHome.gateway.publicEndpoint}:${toString wgHome.gateway.listenPort}'
      WG_HOME_ALLOWED_IPS='${wgHome.cidr}, ${lan.cidr}'
      WG_HOME_PEERS_JSON='${builtins.toJSON (pkgs.lib.mapAttrs (_name: peer: peer.address) wgHome.peers)}'

      usage() {
        cat <<'EOF'
      Usage:
        wg-home-client-config (--peer <inventory-peer-name> | --address <peer-address>/32) --private-key-file <path> [--output <path>] (--server-public-key <key> | --fetch-server-public-key)

      Examples:
        wg-home-client-config --peer mair --private-key-file ./client.key --fetch-server-public-key --output ./client.conf
        wg-home-client-config --address 10.83.0.50/32 --private-key-file ./client.key --fetch-server-public-key --output ./client.conf
        wg-home-client-config --address 10.83.0.50/32 --private-key-file ./client.key --server-public-key "$(<server.pub)"
        Inventory-backed peers: ${pkgs.lib.concatStringsSep ", " (builtins.attrNames wgHome.peers)}
      EOF
      }

      peer_name=""
      address=""
      private_key_file=""
      server_public_key=""
      fetch_server_public_key=false
      output=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --help)
            usage
            exit 0
            ;;
          --peer)
            shift
            peer_name="''${1-}"
            ;;
          --address)
            shift
            address="''${1-}"
            ;;
          --private-key-file)
            shift
            private_key_file="''${1-}"
            ;;
          --server-public-key)
            shift
            server_public_key="''${1-}"
            ;;
          --fetch-server-public-key)
            fetch_server_public_key=true
            ;;
          --output)
            shift
            output="''${1-}"
            ;;
          *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
        esac
        shift || true
      done

      if [ -z "$private_key_file" ]; then
        usage >&2
        exit 1
      fi

      if [ -n "$peer_name" ] && [ -n "$address" ]; then
        echo "Use either --peer or --address, not both." >&2
        exit 1
      fi

      if [ -z "$peer_name" ] && [ -z "$address" ]; then
        echo "One of --peer or --address is required." >&2
        usage >&2
        exit 1
      fi

      if [ ! -f "$private_key_file" ]; then
        echo "Private key file not found: $private_key_file" >&2
        exit 1
      fi

      if [ -n "$server_public_key" ] && [ "$fetch_server_public_key" = true ]; then
        echo "Use either --server-public-key or --fetch-server-public-key, not both." >&2
        exit 1
      fi

      if [ -z "$server_public_key" ] && [ "$fetch_server_public_key" = false ]; then
        echo "One of --server-public-key or --fetch-server-public-key is required." >&2
        exit 1
      fi

      resolved_address="$(${pkgs.python3}/bin/python3 - "$peer_name" "$address" "$WG_HOME_CIDR" "$WG_HOME_PEERS_JSON" <<'PY'
      import ipaddress
      import json
      import sys

      peer_name, explicit, subnet_cidr, peers_json = sys.argv[1:5]
      peers = json.loads(peers_json)

      if peer_name:
          if peer_name not in peers:
              known = ", ".join(sorted(peers)) or "<none>"
              raise SystemExit(f"unknown inventory peer {peer_name!r}; known peers: {known}")
          explicit = peers[peer_name]

      peer = ipaddress.ip_interface(explicit)
      subnet = ipaddress.ip_network(subnet_cidr)

      if peer.version != 4:
          raise SystemExit("peer address must be IPv4")
      if peer.network.prefixlen != 32:
          raise SystemExit("peer address must use /32")
      if peer.ip not in subnet:
          raise SystemExit(f"peer address {peer.ip} is not inside {subnet}")
      print(str(peer))
      PY
      )"

      if [ "$fetch_server_public_key" = true ]; then
        server_public_key="$(ssh ${wireguardGatewaySshHost} "sudo sh -c 'wg pubkey < /var/lib/wireguard/wg0.key'")"
      fi

      private_key="$(${pkgs.coreutils}/bin/tr -d '\n' < "$private_key_file")"
      server_public_key="$(${pkgs.coreutils}/bin/printf '%s' "$server_public_key" | ${pkgs.coreutils}/bin/tr -d '\n')"

      if [ -z "$private_key" ] || [ -z "$server_public_key" ]; then
        echo "Private key and server public key must be non-empty." >&2
        exit 1
      fi

      config_text="$(
        printf '%s\n' \
          '[Interface]' \
          "PrivateKey = $private_key" \
          "Address = $resolved_address" \
          "DNS = $WG_HOME_DNS" \
          "" \
          '[Peer]' \
          "PublicKey = $server_public_key" \
          "Endpoint = $WG_HOME_ENDPOINT" \
          "AllowedIPs = $WG_HOME_ALLOWED_IPS" \
          'PersistentKeepalive = 25'
      )"

      if [ -n "$output" ]; then
        umask 077
        ${pkgs.coreutils}/bin/printf '%s\n' "$config_text" > "$output"
      else
        ${pkgs.coreutils}/bin/printf '%s\n' "$config_text"
      fi
    '';
    inherit
      (mkBatsCheck {
        test = ./wg-home-client-config.bats;
        targetEnvironmentVariable = "WG_HOME_CLIENT_CONFIG_BIN";
        environment.WG_HOME_TEST_ENDPOINT = "${wgHome.gateway.publicEndpoint}:${toString wgHome.gateway.listenPort}";
      })
      derivationArgs
      checkPhase
      ;
  };
in
{
  packages = {
    inherit deploy vm;
    diff = diffConfig;
    get-local-builders = getLocalBuilders;
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
    vm = mkApp "${vm}/bin/vm" "Run a local NixOS VM for a nixosConfigurations host.";
    diff = mkApp "${diffConfig}/bin/diff" "Build and diff a NixOS or nix-darwin host configuration between two Git revisions.";
    "get-local-builders" =
      mkApp "${getLocalBuilders}/bin/get-local-builders" "Read local Nix builders from nix.conf or nix.machines.";
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
