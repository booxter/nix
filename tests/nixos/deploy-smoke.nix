{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  keys = ./backup;
  fleetTools = inputs.self.packages.${system}.fleet-tools.overrideAttrs (
    previous:
    let
      inventory = builtins.fromJSON previous.FLEET_HOSTS_JSON;
    in
    {
      # Extend the normal inventory so the package's existing checks still run.
      # The test realm has no cache, exercising the direct SSH deployment path.
      FLEET_HOSTS_JSON = builtins.toJSON (
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
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "deploy-smoke";

  defaults = {
    system.switch.enable = true;
    environment.etc."deploy-smoke".text = "before\n";
    environment.systemPackages = [
      fleetTools
      pkgs.git
      pkgs.tmux
    ];
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = lib.mkForce [ ];
    };
    users.users.deployer = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      initialPassword = "unused-test-password";
    };
    security.sudo.wheelNeedsPassword = false;
    virtualisation = {
      diskSize = 40 * 1024;
      writableStoreUseTmpfs = false;
    };
  };

  nodes = {
    controller =
      { nodes, ... }:
      let
        paths = pkgs.writeText "deploy-smoke-paths.json" (
          builtins.toJSON {
            helper = toString fleetTools;
            system = toString nodes.target.specialisation.deployed.configuration.system.build.toplevel;
          }
        );
        flake = pkgs.writeText "deploy-smoke-flake.nix" ''
          {
            outputs = { self }:
              let
                paths = builtins.fromJSON (builtins.readFile ./paths.json);
                # Expose realised closures as installables without fetching nixpkgs.
                storePath = path: builtins.appendContext path {
                  "''${path}" = { path = true; };
                };
              in
              {
                packages.${system}.fleet-tools = storePath paths.helper;
                nixosConfigurations.target.config.system.build.toplevel = storePath paths.system;
              };
          }
        '';
      in
      {
        environment.etc."deploy-source".source = pkgs.linkFarm "deploy-smoke-source" [
          {
            name = "flake.nix";
            path = flake;
          }
          {
            name = "paths.json";
            path = paths;
          }
        ];
        systemd.tmpfiles.rules = [
          "d /home/deployer/.ssh 0700 deployer users -"
          "C /home/deployer/.ssh/id_ed25519 0600 deployer users - ${keys}/client-key"
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

    target = {
      users.users.deployer.openssh.authorizedKeys.keyFiles = [ (keys + "/client-key.pub") ];
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys + "/server-key";
        mode = "0600";
      };
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        settings.PasswordAuthentication = false;
      };
      specialisation.deployed.configuration.environment.etc."deploy-smoke".text = lib.mkForce "after\n";
    };
  };

  testScript = builtins.readFile ./deploy-smoke/test.py;
}
