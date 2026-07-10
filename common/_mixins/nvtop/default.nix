{
  hostInventory,
  hostSpecName,
  hostname,
  isDarwin ? false,
  isDesktop ? false,
  isVM ? false,
  lib,
  pkgs,
  ...
}:
let
  hostSpecs = if isDarwin then hostInventory.darwinHosts else hostInventory.nixosHostSpecsByName;
  hostSpec = hostSpecs.${hostSpecName} or { };
  gpuFamilies = hostSpec.hardware.gpuFamilies or [ ];
  knownGpuFamilies = [
    "amd"
    "apple"
    "intel"
  ];
  unknownGpuFamilies = lib.filter (gpu: !(builtins.elem gpu knownGpuFamilies)) gpuFamilies;
  validGpuFamilies = lib.filter (gpu: builtins.elem gpu knownGpuFamilies) gpuFamilies;
  nvtopSupport =
    (lib.genAttrs knownGpuFamilies (_: false)) // (lib.genAttrs validGpuFamilies (_: true));
  shouldInstall = !isVM && isDesktop && gpuFamilies != [ ];
  nvtopPackage =
    if builtins.length validGpuFamilies == 1 then
      pkgs.nvtopPackages.${builtins.head validGpuFamilies}
    else
      pkgs.nvtopPackages.full.override nvtopSupport;
in
{
  assertions = lib.optionals shouldInstall [
    {
      assertion = unknownGpuFamilies == [ ];
      message = "nvtop does not support GPU families for ${hostname}: ${lib.concatStringsSep ", " unknownGpuFamilies}";
    }
  ];

  environment.systemPackages = lib.optionals (shouldInstall && unknownGpuFamilies == [ ]) [
    nvtopPackage
  ];
}
