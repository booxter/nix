{
  description = "booxter Nix* flake configs";

  outputs =
    { self }:
    let
      inputs = import ./.tack // {
        inherit self;
      };
      inherit (self) outputs;
      lib = inputs.nixpkgs.lib;
      hosts = import ./lib/hosts.nix { inherit lib; };
      fleetInventory = import ./inventory {
        fleetHosts = hosts;
        inherit lib;
      };
      sshKeys = fleetInventory.ssh;
      specialArgsForHost =
        {
          hostName,
          system,
        }:
        {
          backupConfigurations = outputs.nixosConfigurations;
          storageConfigurations = outputs.nixosConfigurations;
          inherit
            inputs
            outputs
            hostName
            fleetInventory
            sshKeys
            system
            ;
        };
      mkNixos =
        hostName: hostModule:
        let
          # Keep node modules and base packages on Proxmox's tested nixpkgs pin.
          nixpkgsInput =
            if builtins.hasAttr hostName fleetInventory.proxmox.nodes then
              inputs.proxmox-nixos.inputs.nixpkgs-stable
            else
              inputs.nixpkgs;
        in
        nixpkgsInput.lib.nixosSystem {
          specialArgs = specialArgsForHost {
            inherit hostName;
            system = "x86_64-linux";
          };
          modules = [
            ./nixos
            hostModule
          ];
        };
      mkDarwin =
        hostName: hostModule:
        inputs.nix-darwin.lib.darwinSystem {
          specialArgs = specialArgsForHost {
            inherit hostName;
            system = "aarch64-darwin";
          };
          modules = [
            ./darwin
            hostModule
          ];
        };
      perSystem =
        inputs.nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-darwin"
          ]
          (
            system:
            import ./per-system.nix {
              inherit
                inputs
                fleetInventory
                outputs
                system
                ;
            }
          );
      selectPerSystem = outputName: builtins.mapAttrs (_: value: value.${outputName}) perSystem;
    in
    {
      darwinConfigurations = builtins.mapAttrs mkDarwin hosts.darwin;
      nixosConfigurations = builtins.mapAttrs mkNixos hosts.nixos;

      apps = selectPerSystem "apps";
      checks = selectPerSystem "checks";
      formatter = selectPerSystem "formatter";
      packages = selectPerSystem "packages";
      updatePackages = selectPerSystem "update-packages";

      overlays = import ./overlays { inherit inputs; };

      lib = {
        inputs = import ./.tack;
        ci = {
          inherit (import ./ci { inherit hosts lib; }) buildTargets;
          checks = selectPerSystem "ci-checks";
        };
      };
    };
}
