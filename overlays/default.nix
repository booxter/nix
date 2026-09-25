{ inputs, ... }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications =
    _final: prev:
    let
      inherit (prev) lib;
      system = prev.stdenv.hostPlatform.system;
      pkgsNixpkgsUnstable = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      releaseTransmission = prev.transmission_4;
      releaseTransmissionVersion = lib.getVersion releaseTransmission;
      # Track the release branch now that trackers allow 4.1.x, but fail
      # evaluation before accepting an unvetted 4.2.x+ daemon.
      guardedTransmission = (
        assert lib.asserts.assertMsg (
          lib.versionAtLeast releaseTransmissionVersion "4.1.0"
          && lib.versionOlder releaseTransmissionVersion "4.2.0"
        ) "Transmission must stay on the 4.1.x release series; got ${releaseTransmissionVersion}";
        releaseTransmission
      );
    in
    {
      inherit (pkgsNixpkgsUnstable) aerospace chatgpt codex;

      # The repair planner's Qwen model requires Ollama features newer than
      # the release branch. Keep the base and ROCm variants on one revision.
      inherit (pkgsNixpkgsUnstable) ollama ollama-rocm;

      # Expose Radarr's stable manual-import rejection reason beside its human
      # message so local API consumers do not have to match mutable text.
      radarr = prev.radarr.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/radarr-expose-import-rejection-reason.patch
          ../patches/radarr-use-grab-history-for-ambiguous-title.patch
        ];
      });

      # CI renders two-revision config diffs by calling standalone dix, not
      # nh's internal dix library. Stable dix 1.4.x omits the per-package size
      # deltas that nh 4.4's dix 2.x reports during activation, so keep the CLI
      # on unstable until the stable branch catches up.
      inherit (pkgsNixpkgsUnstable) dix;

      pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
        (pythonFinal: pythonPrev: {
          # FIXME(nixpkgs): pystemd installs complete .pyi files but omits
          # the PEP 561 marker. Fix this in the upstream nixpkgs dependency.
          pystemd = pythonPrev.pystemd.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              touch "$out/${pythonFinal.python.sitePackages}/pystemd/py.typed"
            '';
          });
        })
      ];

      # Build passthru.tests for all changed packages with --tests. Drop when
      # https://github.com/Mic92/nixpkgs-review/pull/397 lands in nixpkgs-review.
      nixpkgs-review = prev.nixpkgs-review.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            # Commit 47f4647, rebased after its first two prerequisite commits
            # landed on main.
            url = "https://github.com/user-attachments/files/29713758/rebased.patch";
            hash = "sha256-euILgOxvghTRf3AwK7BHoC7mKKdmkAEH9iIOqNdN8pE=";
          })
          # Merge dependent PRs into the reviewed worktree with --include-pr.
          # https://github.com/Mic92/nixpkgs-review/pull/562
          (prev.fetchpatch {
            url = "https://github.com/Mic92/nixpkgs-review/commit/1bf8762fcc5c3a3d8b5219ab340f4a3a83608f13.patch";
            hash = "sha256-RQJvXwRLZ47vHi4VhuvKLk8UHYQJfo3SmzUsV9dpNR0=";
          })
        ];
      });

      # Support Kubernetes 1.36 and fix apiserver connection loss after an
      # envoy load balancer container restart.
      inherit (pkgsNixpkgsUnstable) kind;

      lolek =
        let
          lolekPackage = inputs.lolek.packages.${system}.lolek;
          lolekYtDlp = pkgsNixpkgsUnstable.yt-dlp.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ../patches/yt-dlp-twitter-only-own-status-media.patch
            ];
          });
        in
        lolekPackage.override { yt-dlp = lolekYtDlp; };

      # Advertise ReFrame's absolute pointer as a touchscreen only. Declaring
      # the same uinput device as both absolute and relative breaks movement
      # under some compositors. Drop once a release contains this commit.
      reframe = prev.reframe.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/AlynxZhou/reframe/commit/c028f5f840638ba6eb1703393ee81315474264d1.patch";
            hash = "sha256-ETB/kbPFoRER/w49oVHrjY1AhBvlNWTrXlXvWBY/yvw=";
          })
        ];
      });

      transmission_4 = guardedTransmission;
      transmission = guardedTransmission;

      # NixOS can expose the same D-Bus service file through both direct package
      # paths and system-path symlinks. Do not let dbus-broker report those
      # same-file duplicates at error level.
      # https://github.com/NixOS/nixpkgs/issues/303078
      dbus-broker = prev.dbus-broker.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/dbus-broker-ignore-duplicate-canonical-service-paths.patch
        ];
      });

      audiobookshelf = prev.audiobookshelf.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ prev.makeWrapper ];
        patches = (old.patches or [ ]) ++ [
          # Extract cover images from PDF ebooks.
          # Upstream: https://github.com/advplyr/audiobookshelf/issues/1479
          # https://github.com/booxter/audiobookshelf/tree/pdf-images
          (prev.fetchpatch {
            url = "https://github.com/booxter/audiobookshelf/commit/2741f471f1fb31c3445be90ed4c9dc7c61ea0cde.patch";
            hash = "sha256-eYE19TmqTk5TWU0A88kbFAW3e74BdiW122BJYX/c728=";
          })
          (prev.fetchpatch {
            url = "https://github.com/booxter/audiobookshelf/commit/662feb56b871667addacaf1042647e379fe9629b.patch";
            hash = "sha256-ufFfGyMQFtTVxQK/p2gE6Z9DsvamRBgNZdixWuH8cX4=";
          })
          (prev.fetchpatch {
            url = "https://github.com/booxter/audiobookshelf/commit/5f6d2919d1c747f4125f6a05a9b665e27ea905d4.patch";
            hash = "sha256-4oaEM7HvFFlcxRXRIbIzOJpQNb7/rY2XWkI2+zwH3OA=";
          })
        ];
        postFixup = (old.postFixup or "") + ''
          wrapProgram "$out/bin/audiobookshelf" \
            --set PDFTOPPM_PATH ${lib.getExe' prev.poppler-utils "pdftoppm"}
        '';
      });

      jellyfin = prev.jellyfin.overrideAttrs (old: {
        patches = old.patches or [ ] ++ [
          # Catch websocket keepalive send races.
          # Upstream: https://github.com/jellyfin/jellyfin/issues/14837
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/b5a385d185.patch";
            hash = "sha256-maX9MLOK/lq/6LPpJi2Dw8ZZTvzSR9t15648JT0jS2Q=";
          })
          # Catch websocket close teardown races while testing fixes for Jellyfin coredumps.
          # Upstream: https://github.com/jellyfin/jellyfin/issues/16512
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/c64abc489e.patch";
            hash = "sha256-/Y2QiBkeLY4Wi+RlgFcNuzLPuwOF1sRyf7hnBuUEzAM=";
          })
          # Ignore stale progress updates unless transcode job exists.
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/3b63ec92420305d24e0fe90a452f0cdcbb624872.patch";
            hash = "sha256-X5qv8+R2s/zk411gQHyNhRaf9VRFSG+47W8Fy0N+96U=";
          })
          # GHSA-6828-c7cx-hvqm: confine virtual-folder operations to the
          # libraries root.
          (prev.fetchpatch {
            url = "https://github.com/jellyfin/jellyfin/commit/0c560b22ce73323329645b836c9910abc257ce4e.patch";
            hash = "sha256-K/og9MDP4BNexkDGLOm346O9anqAjb13UViSAmOw2OA=";
          })
          # GHSA-4vx8-xhc9-qg6x: enforce remote-control permissions between
          # user sessions.
          (prev.fetchpatch {
            url = "https://github.com/jellyfin/jellyfin/commit/dd7de4187879082e10b474856f705b6c5d9b963a.patch";
            hash = "sha256-OCj4aaKaX4F/+KbCz6BAsifdYe/6BOu6y39ZgMSUKFA=";
          })
        ];
      });

      vikunja = prev.vikunja.overrideAttrs (
        old:
        let
          frontend = prev.vikunja.frontend.overrideAttrs (frontendOld: {
            patches = (frontendOld.patches or [ ]) ++ [
              # TODO: send upstream.
              # Confirm label creation from the multiselect input.
              ../patches/vikunja-confirm-label-creation.patch
            ];
          });
        in
        {
          inherit frontend;
          prePatch = ''
            cp -r ${frontend} frontend/dist
          '';
          passthru = old.passthru // {
            inherit frontend;
          };
        }
      );

      # Torrent-client jobs can legitimately sit queued/checking without progress
      # or message churn for much longer than 5 minutes. Keep Shelfmark's stall
      # canceller for direct downloads, but do not auto-cancel torrent jobs.
      shelfmark = prev.shelfmark.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/shelfmark-disable-torrent-stall-cancel.patch
          ../patches/shelfmark-add-download-poll-debug-state.patch
          ../patches/shelfmark-add-download-diagnostic-signal.patch
          ../patches/shelfmark-add-throttled-poll-heartbeat-logs.patch
        ];
      });
    }
    // lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
      darwin = prev.darwin.overrideScope (
        _: _: {
          inherit (pkgsNixpkgsUnstable.darwin) linux-builder-vz;
        }
      );
    };
}
