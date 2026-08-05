{
  config,
  hostInventory,
  hostname,
  lib,
  pkgs,
  ...
}:
let
  hostSpec = hostInventory.hostSpecsByName.${hostname} or { };
  gpuFamilies = hostSpec.hardware.gpuFamilies or [ ];
  knownGpuFamilies = [
    "amd"
    "apple"
    "intel"
    "nvidia"
  ];
  unknownGpuFamilies = lib.filter (gpu: !(builtins.elem gpu knownGpuFamilies)) gpuFamilies;
  validGpuFamilies = lib.filter (gpu: builtins.elem gpu knownGpuFamilies) gpuFamilies;
  nvtopSupport =
    (lib.genAttrs knownGpuFamilies (_: false)) // (lib.genAttrs validGpuFamilies (_: true));
  shouldInstall = !config.host.isVM && gpuFamilies != [ ];
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
