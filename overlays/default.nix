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
      # Temporary Darwin firefox wrapper backport:
      # in our pinned nixpkgs revision, wrapper logic copies only *.dylib symlinks.
      # Some shared libraries are Mach-O dylibs without that suffix, which leaves them
      # symlinked and breaks runtime features (e.g. Crypto API / media codecs).
      # Drop this once nixpkgs PR #488112 (or equivalent) is in the pinned input.
      patchFirefoxDarwinWrapper =
        pkg:
        pkg.overrideAttrs (old: {
          buildCommand = old.buildCommand + ''
            # Backport nixpkgs#488112 with otool-based dylib detection.
            cd "$out/Applications/Firefox.app"

            find . -type l -print0 | while IFS= read -r -d $'\0' file; do
              case "$(basename "$file")" in
                omni.ja)
                  ;;
                *)
                  otool -l "$file" 2>/dev/null | grep -q 'LC_ID_DYLIB' || continue
                  ;;
              esac

              target="$(readlink -f "$file")"
              rm "$file"
              cp "$target" "$file"
            done
          '';
        });
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

      # Backport until https://github.com/NixOS/nixpkgs/pull/488112 lands in our pinned nixpkgs.
      firefox = patchFirefoxDarwinWrapper prev.firefox;

      # Pull XQuartz stack from a fork until quartz-wm changes are merged:
      # https://github.com/NixOS/nixpkgs/pull/491935
      xquartz = pkgsQuartzWm.xquartz;
      quartz-wm = pkgsQuartzWm."quartz-wm";
    };
}
