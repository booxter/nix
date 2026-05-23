{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  pythonWithPromptToolkit = pkgs.python3.withPackages (ps: [ ps."prompt-toolkit" ]);
  hostInventory = import ../lib/inventory.nix { lib = pkgs.lib; };
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
  unifiSyncEnv = import ./unifi-sync-env.nix { inherit hostInventory; };

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

  deploy = pkgs.writeShellApplication {
    name = "deploy";
    runtimeInputs = with pkgs; [
      bind
      git
      home-manager
      jq
      nix
      openssh
      pythonWithPromptToolkit
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage:
        deploy [fleet deploy args]
        deploy --home <target> [username]
        deploy --disko <host> <device>

      Examples:
        deploy -A --select
        deploy --branch ci/flake-update --boot prox-srvarrvm
        deploy --home nv ihrachyshka
        deploy --disko frame /dev/sdX
      EOF
      }

      if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "$#" -gt 0 ] && [ "$1" = "--home" ]; then
        shift

        if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
          usage >&2
          exit 1
        fi

        target="$1"
        username="''${USERNAME:-ihrachyshka}"
        if [ "$#" -eq 2 ]; then
          username="$2"
        fi

        exec home-manager switch --flake "${../.}#''${username}@''${target}" -L --show-trace -b backup
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

      exec ${pkgs.bash}/bin/bash ${../.}/scripts/update-machines.sh "$@"
    '';
  };

  vm = pkgs.writeShellApplication {
    name = "vm";
    runtimeInputs = with pkgs; [
      jq
      nix
    ];
    text = ''
      export VM_REPO_ROOT="${../.}"
      exec ${pkgs.bash}/bin/bash ${../scripts/vm.sh} "$@"
    '';
  };

  getLocalBuilders = pkgs.writeShellApplication {
    name = "get-local-builders";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gawk
    ];
    text = ''
      exec ${../scripts/get-local-builders.sh} "$@"
    '';
  };

  hbaFlash = pkgs.writeShellApplication {
    name = "hba-flash";
    runtimeInputs = with pkgs; [
      bash
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
    + builtins.readFile ../scripts/hba-flash.sh;
  };
  unifiSyncPackage = pkgs.unifi-sync;
  unifiSyncApp = pkgs.writeShellApplication {
    name = "unifi-sync-app";
    runtimeInputs = [ unifiSyncPackage ];
    text = ''
      ${pkgs.lib.concatLines (
        pkgs.lib.mapAttrsToList (
          name: value: "export ${name}=${pkgs.lib.escapeShellArg value}"
        ) unifiSyncEnv.environment
      )}
      exec ${unifiSyncPackage}/bin/unifi-sync "$@"
    '';
  };
  wgHomeClientConfig = pkgs.writeShellApplication {
    name = "wg-home-client-config";
    runtimeInputs = with pkgs; [
      coreutils
      openssh
      python3
    ];
    text = ''
      set -euo pipefail

      WG_HOME_CIDR='${wgHome.cidr}'
      WG_HOME_DNS='${lan.gateway.address}'
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
        server_public_key="$(ssh prox-gwvm 'sudo wg pubkey < /var/lib/wireguard/wg0.key')"
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
  };
in
{
  deploy = mkApp "${deploy}/bin/deploy" "Apply fleet operations: host deploys (default), standalone Home Manager (--home), or disk provisioning (--disko).";
  vm = mkApp "${vm}/bin/vm" "Run a local NixOS VM for a nixosConfigurations host via local-<target-host>vm.";
  "get-local-builders" =
    mkApp "${getLocalBuilders}/bin/get-local-builders" "Read local Nix builders from nix.conf or nix.machines.";
  "unifi-sync" =
      mkApp
      "${unifiSyncApp}/bin/unifi-sync-app"
      "Sync UniFi DHCP, reservations, and split DNS from inventory.";
  "join-media-parts" =
    mkApp "${pkgs.join-media-parts}/bin/join-media-parts" "Join ordered TS/MP4/MKV media parts into one file.";
  "hba-flash" =
    mkApp "${hbaFlash}/bin/hba-flash" "Preflight and flash the Broadcom/LSI HBA on beast using pinned Broadcom bundles by default.";
  "wg-home-client-config" =
    mkApp "${wgHomeClientConfig}/bin/wg-home-client-config" "Generate a home WireGuard client config from fleet topology.";
}
