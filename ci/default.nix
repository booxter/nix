{
  hostInventory,
  lib,
}:
let
  runners = {
    aarch64-darwin = "macos-26";
    x86_64-linux = "ubuntu-latest";
  };
  mkTarget =
    {
      attr,
      diff ? false,
      host,
      name,
      system,
    }:
    {
      inherit
        attr
        host
        name
        system
        ;
      inherit diff;
      runner = runners.${system} or (throw "No CI runner configured for ${system}");
    };
  mkNixosTarget =
    spec:
    mkTarget {
      attr = "nixosConfigurations.${spec.name}.config.system.build.toplevel";
      diff = true;
      host = spec.name;
      name = "${spec.name} (${spec.platform})";
      system = spec.platform;
    };
  mkDarwinTarget =
    name: spec:
    mkTarget {
      attr = "darwinConfigurations.${name}.system";
      diff = true;
      host = name;
      name = "${name} (${spec.platform})";
      system = spec.platform;
    };
  builderSystem = hostInventory.nixosHosts.builder1.platform;
  buildTargets =
    map mkNixosTarget hostInventory.nixosHostSpecs
    ++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts
    ++ [
      (mkTarget {
        attr = "nixosConfigurations.builder1.config.system.build.vm";
        host = "builder1";
        name = "nixos vm builder1 (${builderSystem})";
        system = builderSystem;
      })
      (mkTarget {
        attr = "nixosConfigurations.builder1.config.system.build.vmQemu";
        host = "builder1";
        name = "nixos vm qemu (${builderSystem})";
        system = builderSystem;
      })
      (mkTarget {
        attr = "packages.aarch64-darwin.qemu-host-package";
        host = "builder1";
        name = "nixos vm qemu (aarch64-darwin)";
        system = "aarch64-darwin";
      })
      (mkTarget {
        attr = "nixosConfigurations.builder1.config.virtualisation.proxmox.iso";
        host = "builder1";
        name = "nixos vm proxmox iso (${builderSystem})";
        system = builderSystem;
      })
    ];
  githubActionsBuildMatrix = {
    include = lib.imap0 (index: target: {
      name = target.name;
      cmd = "nix build .#${target.attr} -L --show-trace";
      diff_machine = if target.diff then target.host else "";
      diff_order = if target.diff then lib.fixedWidthString 3 "0" (toString index) else "";
      os = target.runner;
    }) buildTargets;
  };
in
{
  buildTargets = map (target: builtins.removeAttrs target [ "diff" ]) buildTargets;
  inherit githubActionsBuildMatrix;
}
