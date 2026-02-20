{ inputs, ... }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications =
    _final: prev:
    let
      getPkgs =
        np:
        import np {
          inherit (prev) system;
          config = {
            allowUnfree = true;
          };
        };

      pkgs = getPkgs inputs.nixpkgs;
      pkgsLldb = getPkgs inputs.debugserver;
      pkgsMaster = getPkgs inputs.nixpkgs-master;
      pkgsRelease = getPkgs inputs.nixpkgs-25_11;
      pkgsQuartzWm = getPkgs inputs.nixpkgs-quartz-wm;
      pkgsHuntarr = getPkgs inputs.nixpkgs-huntarr;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      releaseTransmission =
        if prev.lib.strings.hasPrefix "4.0." pkgsRelease.transmission_4.version then
          pkgsRelease.transmission_4
        else
          throw "Expected transmission_4 from nixpkgs-25_11 to be 4.0.x, got ${pkgsRelease.transmission_4.version}";
    in
    {
      inherit (llmAgentsPkgs) codex claude-code;

      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
      inherit (pkgs) netbootxyz-efi;

      # Pull Sonarr/Readarr and pin Transmission to 4.0.x from release-25.11.
      # TODO: report issues; investigate; fix
      inherit (pkgsRelease) readarr sonarr;
      transmission_4 = releaseTransmission;
      transmission = releaseTransmission;

      # Huntarr from fork until it lands upstream
      inherit (pkgsHuntarr) huntarr;

      jellyfin = prev.jellyfin.overrideAttrs (old: {
        patches = old.patches or [ ] ++ [
          # fix directors not populated for new movies since 10.11.6
          (prev.fetchpatch {
            url = "https://github.com/jellyfin/jellyfin/commit/673f617994da6ff6a45cf428a3ea47de59edc6c5.patch";
            hash = "sha256-iHriDqPqJ5Xcdrq905sdSxMmEvr4hWmNrzU5CDFFJyY=";
          })
        ];
      });
    }
    // inputs.nixpkgs.lib.optionalAttrs prev.stdenv.isDarwin {
      # Pull NUT from master for now for darwin support.
      inherit (pkgsMaster) nut;

      # Pull XQuartz stack from a fork until quartz-wm changes are merged:
      # https://github.com/NixOS/nixpkgs/pull/491935
      xquartz = pkgsQuartzWm.xquartz;
      quartz-wm = pkgsQuartzWm."quartz-wm";
    };
}
