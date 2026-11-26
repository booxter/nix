{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
{
  # TODO(26.11): Drop the intermediate package and its upstream restart
  # policy once the live database is ready for Aurral 3.
  services.aurral.package =
    inputs.nixpkgs-aurral.legacyPackages.${pkgs.stdenv.hostPlatform.system}.aurral_213;
  systemd.services.aurral.serviceConfig.Restart = lib.mkForce "always";

  host.aurral = {
    stateDir = "/data/.state/nixarr/aurral";
    storageClaim = "media";
    libraryRoots = [ "/data/media/library/music" ];
    publicHostName = "mu.${config.host.network.publicDomain}";
  };
}
