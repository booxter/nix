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
      pkgsRelease = getPkgs inputs.nixpkgs-25_11;
      pkgsQuartzWm = getPkgs inputs.nixpkgs-quartz-wm;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      releaseTransmission = pkgsRelease.transmission_4.overrideAttrs (_old: rec {
        version = "4.0.6";
        src = prev.fetchFromGitHub {
          owner = "transmission";
          repo = "transmission";
          tag = version;
          hash = "sha256-KBXvBFgrJ3njIoXrxHbHHLsiocwfd7Eba/GNI8uZA38=";
          fetchSubmodules = true;
        };
      });
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
      # Backport until https://github.com/NixOS/nixpkgs/pull/488112 lands in our pinned nixpkgs.
      firefox = patchFirefoxDarwinWrapper prev.firefox;

      # Pull XQuartz stack from a fork until quartz-wm changes are merged:
      # https://github.com/NixOS/nixpkgs/pull/491935
      xquartz = pkgsQuartzWm.xquartz;
      quartz-wm = pkgsQuartzWm."quartz-wm";

      # Backport until this lands in our pinned nixpkgs:
      # https://github.com/NixOS/nixpkgs/pull/485980
      dbus = prev.dbus.overrideAttrs (
        old:
        let
          hasMergedSessionBusFix = builtins.elem "-Ddbus_session_bus_listen_address=unix:tmpdir=/tmp" (
            old.mesonFlags or [ ]
          );
          hasMergedInstallNameFix = inputs.nixpkgs.lib.hasInfix "@rpath/libdbus-1.3.dylib" (
            old.postInstall or ""
          );
        in
        assert
          (!(hasMergedSessionBusFix || hasMergedInstallNameFix))
          || throw ''
            dbus Darwin backport for nixpkgs#485980 appears to be upstream now.
            Remove the temporary dbus override from overlays/default.nix.
          '';
        {
          mesonFlags = (old.mesonFlags or [ ]) ++ [
            # D-Bus defaults to launchd activation on Darwin, but that requires a
            # launch agent and breaks dbus-run-session in tests.
            "-Ddbus_session_bus_listen_address=unix:tmpdir=/tmp"
          ];

          postInstall = (old.postInstall or "") + ''
            # Match nixpkgs#485980 install_name fixup on Darwin.
            for exe in bin/dbus-daemon bin/dbus-run-session libexec/dbus-daemon-launch-helper; do
              install_name_tool "$out/$exe" \
                -change "@rpath/libdbus-1.3.dylib" "$lib/lib/libdbus-1.3.dylib"
            done
          '';
        }
      );

      # Backport until this lands in our pinned nixpkgs:
      # https://github.com/NixOS/nixpkgs/pull/496019
      pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
        (python-final: python-prev: {
          accelerate = python-prev.accelerate.overridePythonAttrs (
            old:
            let
              hasMergedTransformersCheckInput = builtins.any (
                dep:
                builtins.isAttrs dep
                && (
                  (dep ? pname && dep.pname == "transformers")
                  || (dep ? name && inputs.nixpkgs.lib.hasInfix "transformers" dep.name)
                )
              ) (old.checkInputs or [ ]);
            in
            assert
              (!hasMergedTransformersCheckInput)
              || throw ''
                accelerate Darwin backport for https://github.com/NixOS/nixpkgs/pull/496019 appears to be upstream now.
                Remove the temporary accelerate override from overlays/default.nix.
              '';
            {
              # pytest fails without this on Darwin.
              checkInputs = (old.checkInputs or [ ]) ++ [ python-final.transformers ];
            }
          );
        })
      ];
    };
}
