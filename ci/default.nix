{
  facts,
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
      runner = runners.${system} or (throw "No CI runner configured for ${system}");
    };
  mkNixosTarget =
    spec:
    mkTarget {
      attr = "nixosConfigurations.${spec.name}.config.system.build.toplevel";
      host = spec.name;
      name = "${spec.name} (${spec.platform})";
      system = spec.platform;
    };
  mkDarwinTarget =
    name: spec:
    mkTarget {
      attr = "darwinConfigurations.${name}.system";
      host = name;
      name = "${name} (${spec.platform})";
      system = spec.platform;
    };
  builderSystem = facts.hosts.nixos.builder1.platform;
in
{
  buildTargets =
    lib.mapAttrsToList (_: mkNixosTarget) facts.hosts.nixos
    ++ lib.mapAttrsToList mkDarwinTarget facts.hosts.darwin
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
}
