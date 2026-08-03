let
  flake = builtins.getFlake (builtins.getEnv "VM_REPO_ROOT");
  inherit (flake.inputs.nixpkgs) lib;
  targetConfig = builtins.getEnv "VM_TARGET_CONFIG";
  hostPkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  gui = builtins.getEnv "VM_GUI" == "1";
  configuration = (builtins.getAttr targetConfig flake.nixosConfigurations).extendModules {
    modules = [
      {
        virtualisation.vmVariant.virtualisation.host.pkgs = lib.mkForce hostPkgs;
      }
    ]
    ++ lib.optional gui {
      virtualisation.vmVariant.virtualisation.graphics = lib.mkForce true;
    };
  };
in
configuration.config.system.build.vm
