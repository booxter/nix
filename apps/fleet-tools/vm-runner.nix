let
  # Exclude ignored VM disks and control sockets from the flake source.
  flake = builtins.getFlake ("git+file://" + builtins.getEnv "VM_REPO_ROOT");
  inherit (flake.lib.inputs.nixpkgs) lib;
  targetConfig = builtins.getEnv "VM_TARGET_CONFIG";
  isDarwin = builtins.hasAttr targetConfig flake.darwinConfigurations;
  configurations = if isDarwin then flake.darwinConfigurations else flake.nixosConfigurations;
  hostPkgs = import flake.lib.inputs.nixpkgs { system = builtins.currentSystem; };
  gui = builtins.getEnv "VM_GUI" == "1";
  configuration = (builtins.getAttr targetConfig configurations).extendModules {
    modules =
      lib.optional (!isDarwin) {
        virtualisation.vmVariant.virtualisation.host.pkgs = lib.mkForce hostPkgs;
      }
      ++ lib.optional gui {
        virtualisation.vmVariant.virtualisation.graphics = lib.mkForce true;
      };
  };
in
configuration.config.system.build.vm
