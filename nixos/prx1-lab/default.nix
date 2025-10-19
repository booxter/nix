{ ... }:
{
  imports = [
    (import ../../disko { })
  ];

  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

  # Configure AMD GPU for passthru
  boot.initrd.kernelModules = [
    "vfio_pci"
    "vfio"
    "vfio_iommu_type1"
   ];

  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    "vfio-pci.ids=1002:13c0"
  ];

  boot.blacklistedKernelModules = [ "amdgpu" ];
}
