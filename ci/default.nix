{
  hosts,
  lib,
}:
let
  darwinSystem = "aarch64-darwin";
  nixosSystem = "x86_64-linux";
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
    name: _module:
    mkTarget {
      attr = "nixosConfigurations.${name}.config.system.build.toplevel";
      host = name;
      name = "${name} (${nixosSystem})";
      system = nixosSystem;
    };
  mkDarwinTarget =
    name: _spec:
    mkTarget {
      attr = "darwinConfigurations.${name}.system";
      host = name;
      name = "${name} (${darwinSystem})";
      system = darwinSystem;
    };
in
{
  buildTargets =
    lib.mapAttrsToList mkNixosTarget hosts.nixos
    ++ lib.mapAttrsToList mkDarwinTarget hosts.darwin
    ++ [
      (mkTarget {
        attr = "nixosConfigurations.builder1.config.system.build.vm";
        host = "builder1";
        name = "nixos vm builder1 (${nixosSystem})";
        system = nixosSystem;
      })
      (mkTarget {
        attr = "nixosConfigurations.builder1.config.virtualisation.vmVariant.virtualisation.host.pkgs.qemu";
        host = "builder1";
        name = "nixos vm qemu (${nixosSystem})";
        system = nixosSystem;
      })
      (mkTarget {
        attr = "packages.aarch64-darwin.qemu-host-package";
        host = "builder1";
        name = "nixos vm qemu (aarch64-darwin)";
        system = darwinSystem;
      })
      (mkTarget {
        attr = "nixosConfigurations.builder1.config.virtualisation.proxmox.iso";
        host = "builder1";
        name = "nixos vm proxmox iso (${nixosSystem})";
        system = nixosSystem;
      })
    ];
}
