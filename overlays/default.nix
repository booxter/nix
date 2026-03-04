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
      releaseTransmission = prev.callPackage ../pkgs/transmission_4/default.nix { };
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
      # Pull XQuartz stack from a fork until quartz-wm changes are merged:
      # https://github.com/NixOS/nixpkgs/pull/491935
      xquartz = pkgsQuartzWm.xquartz;
      quartz-wm = pkgsQuartzWm."quartz-wm";

      # Backport until this lands in our pinned nixpkgs:
      # https://github.com/NixOS/nixpkgs/pull/496019
      pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
        (
          python-final: python-prev:
          let
            # Backport until this lands in our pinned nixpkgs:
            # https://github.com/NixOS/nixpkgs/pull/485980
            dbusForJeepney = prev.dbus.overrideAttrs (
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
                  dbus Darwin backport for https://github.com/NixOS/nixpkgs/pull/485980 appears to be upstream now.
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
          in
          {
            jeepney = python-prev.jeepney.override {
              dbus = dbusForJeepney;
            };

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
                # ImportError: cannot import name 'PretrainedConfig' from
                # transformers.modeling_utils (matches nixpkgs#494591).
                disabledTests = (old.disabledTests or [ ]) ++ [ "test_nested_hook" ];
              }
            );
          }
        )
      ];
    };
}
