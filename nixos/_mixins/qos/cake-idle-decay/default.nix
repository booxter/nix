{
  config,
  lib,
  pkgs,
  ...
}:
{
  # TODO(cake): Upstream the fix to Linus's tree once broader testing validates
  # the elapsed idle-time decay approach.
  options.host.qos.cakeIdleDecay.enable =
    lib.mkEnableOption "elapsed idle-time decay for CAKE's BLUE penalty";

  config = lib.mkIf config.host.qos.cakeIdleDecay.enable {
    boot.extraModulePackages = [
      (import ./package.nix {
        inherit pkgs;
        kernel = config.boot.kernelPackages.kernel;
      })
    ];
    boot.kernelModules = [ "sch_cake" ];
  };
}
