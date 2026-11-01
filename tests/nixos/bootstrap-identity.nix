{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  keys = ./backup;
  json = pkgs.formats.json { };
  # These are public test fixtures, never identities for managed machines.
  plaintext = json.generate "bootstrap-test-secrets.json" {
    nix.builder_private_key = builtins.readFile (keys + "/client-key");
    bootstrap_password = "!bootstrap-fixture";
  };
  encrypted =
    pkgs.runCommand "bootstrap-test-secrets.json"
      {
        nativeBuildInputs = [
          pkgs.sops
          pkgs.ssh-to-age
        ];
      }
      ''
        recipient=$(ssh-to-age -i ${keys}/server-key.pub)
        sops --encrypt --age "$recipient" --input-type json --output-type json \
          ${plaintext} > "$out"
      '';
  fleetTools = inputs.self.packages.${system}.fleet-tools.overrideAttrs (previous: {
    FLEET_HOSTS_JSON = builtins.toJSON (
      let
        inventory = builtins.fromJSON previous.FLEET_HOSTS_JSON;
      in
      inventory
      // {
        aliases = inventory.aliases // {
          target = "target";
        };
        lanDnsServer = "127.0.0.1";
        lanDomain = "test";
        nixos = inventory.nixos // {
          target = {
            displayName = "target";
            platform = system;
            realm = "test";
            runtimeHost = "target";
            sshHost = "target";
          };
        };
      }
    );
  });
  builderClient = {
    nix = {
      distributedBuilds = true;
      buildMachines = [
        {
          hostName = "builder";
          inherit system;
          protocol = "ssh-ng";
          sshUser = "root";
          sshKey = "/run/secrets/nix/builder_private_key";
        }
      ];
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        max-jobs = 0;
        substituters = lib.mkForce [ ];
      };
    };
    programs.ssh.knownHosts.builder.publicKeyFile = keys + "/server-key.pub";
  };
  targetNetwork = {
    hostName = "target";
    useDHCP = false;
    interfaces.eth1 = {
      ipv4.addresses = [
        {
          address = "192.168.1.3";
          prefixLength = 24;
        }
      ];
      ipv6.addresses = [
        {
          address = "2001:db8:1::3";
          prefixLength = 64;
        }
      ];
    };
    hosts."192.168.1.1" = [ "builder" ];
  };
  installed = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      inputs.disko.nixosModules.disko
      (import ../../nixos/_mixins/disko/plain.nix { device = "/dev/vda"; })
      inputs.sops-nix.nixosModules.sops
      (pkgs.path + "/nixos/modules/testing/test-instrumentation.nix")
      (pkgs.path + "/nixos/modules/profiles/qemu-guest.nix")
      (pkgs.path + "/nixos/modules/profiles/minimal.nix")
      builderClient
      ({ config, ... }: {
        nixpkgs.pkgs = pkgs;
        system.stateVersion = "26.05";
        # Inputs for the uncached helper fixture must exist during evaluation.
        system.extraDependencies = [
          fleetTools
          pkgs.bash
          pkgs.coreutils
        ];
        networking = targetNetwork;
        boot.loader.grub.extraConfig = "serial; terminal_output serial";
        sops = {
          defaultSopsFile = toString encrypted;
          defaultSopsFormat = "json";
          age = {
            keyFile = null;
            generateKey = false;
            sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
          };
          useSystemdActivation = true;
          secrets."nix/builder_private_key" = { };
          secrets.bootstrap_password.neededForUsers = true;
        };
        users.users.bootstrap = {
          isNormalUser = true;
          hashedPasswordFile = config.sops.secrets.bootstrap_password.path;
        };
        users.users.deployer = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          initialPassword = "unused-test-password";
          openssh.authorizedKeys.keyFiles = [ (keys + "/client-key.pub") ];
        };
        security.sudo.wheelNeedsPassword = false;
        services.openssh.enable = true;
        users.users.root.openssh.authorizedKeys.keyFiles = [ (keys + "/client-key.pub") ];
        environment.etc."bootstrap-marker".text = "before\n";
        specialisation.deployed.configuration.environment.etc."bootstrap-marker".text =
          lib.mkForce "after\n";
      })
    ];
  };
  installer = pkgs.nixos {
    imports = [
      (import ../../nixos/_mixins/proxmox/installer.nix {
        inherit inputs pkgs;
        installedSystem = installed;
        publicHostKey = builtins.readFile (keys + "/server-key.pub");
      })
      (pkgs.path + "/nixos/modules/testing/test-instrumentation.nix")
      builderClient
    ];
    networking = targetNetwork;
    boot.loader.timeout = lib.mkForce 1;
    systemd.services.installer = {
      serviceConfig = {
        StandardOutput = lib.mkForce "journal+console";
        StandardError = lib.mkForce "journal+console";
      };
    };
  };
  paths = json.generate "bootstrap-deploy-paths.json" {
    bash = toString pkgs.bash;
    coreutils = toString pkgs.coreutils;
    helper = toString fleetTools;
    system = toString installed.config.specialisation.deployed.configuration.system.build.toplevel;
  };
  flake = pkgs.writeText "bootstrap-deploy-flake.nix" ''
    {
      outputs = { self }:
        let
          paths = builtins.fromJSON (builtins.readFile ./paths.json);
          storePath = path: builtins.appendContext path {
            "''${path}" = { path = true; };
          };
        in {
          # Force a real, uncached helper build during the first deployment.
          # The system variant is prebuilt so this test isolates bootstrap access.
          packages.${system}.fleet-tools = builtins.derivation {
            name = "bootstrap-deploy-helper";
            system = "${system}";
            builder = "''${storePath paths.bash}/bin/bash";
            args = [ "-euc" '''
              ''${storePath paths.coreutils}/bin/mkdir -p "$out/bin"
              ''${storePath paths.coreutils}/bin/ln -s \
                ''${storePath paths.helper}/bin/fleet-deploy-remote "$out/bin/fleet-deploy-remote"
              # Do not exec ln: closing its log stream can make Nix kill
              # the builder before ln has exited.
              exit 0
            ''' ];
            allowSubstitutes = false;
          };
          nixosConfigurations.target.config.system.build.toplevel = storePath paths.system;
        };
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "bootstrap-identity";
  globalTimeout = 900;
  defaults.nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nodes = {
    builder = {
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keyFiles = [ (keys + "/client-key.pub") ];
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys + "/server-key";
        mode = "0600";
      };
      system.extraDependencies = [
        fleetTools
        pkgs.bash
        pkgs.coreutils
      ];
      nix.settings.substituters = lib.mkForce [ ];
    };
    controller = {
      virtualisation.diskSize = 40 * 1024;
      environment.systemPackages = [
        pkgs.git
        pkgs.tmux
        fleetTools
      ];
      environment.etc = {
        "deploy-source".source = pkgs.linkFarm "bootstrap-deploy-source" [
          {
            name = "flake.nix";
            path = flake;
          }
          {
            name = "paths.json";
            path = paths;
          }
        ];
      };
      networking.hosts = {
        "192.168.1.3" = [ "target" ];
        "2001:db8:1::3" = [ "target" ];
      };
      systemd.tmpfiles.rules = [
        "d /root/.ssh 0700 root root -"
        "C /root/.ssh/id_ed25519 0600 root root - ${keys}/client-key"
      ];
      programs.ssh = {
        knownHosts.target.publicKeyFile = keys + "/server-key.pub";
        extraConfig = ''
          Host target
            User deployer
            BatchMode yes
            StrictHostKeyChecking yes
        '';
      };
    };
  };
  testScript = ''
    QEMU = ${builtins.toJSON "${pkgs.qemu_test}/bin/qemu-kvm"}
    QEMU_IMG = ${builtins.toJSON "${pkgs.qemu_test}/bin/qemu-img"}
    INSTALLER_ISO_DIRECTORY = ${builtins.toJSON "${installer.config.system.build.isoImage}/iso"}
    HOST_KEY = ${builtins.toJSON (keys + "/server-key")}
    WRONG_KEY = ${builtins.toJSON (keys + "/client-key")}
  ''
  + builtins.readFile ./bootstrap-identity/test.py;
}
