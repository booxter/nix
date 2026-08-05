{ inputs, ... }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications =
    final: prev:
    let
      inherit (prev) lib;

      getPkgs =
        np:
        import np {
          inherit (prev) system;
          config = {
            allowUnfree = true;
          };
        };

      pkgsNixpkgsUnstable = getPkgs inputs.nixpkgs-unstable;
      withServarrSsoReauthentication =
        package:
        package.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./servarr-sso-reauthentication.patch ];
          nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ prev.nodejs ];
          postCheck = (old.postCheck or "") + ''
            ${lib.getExe prev.nodejs} --test tests/sso-reauth.test.mjs
          '';
        });
      withStandaloneSsoReauthentication =
        package: patch: testPath:
        package.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ patch ];
          doCheck = true;
          nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ prev.nodejs ];
          checkPhase = ''
            runHook preCheck
            ${lib.getExe prev.nodejs} --test "$NIX_BUILD_TOP/$sourceRoot/${testPath}"
            runHook postCheck
          '';
        });
      releaseTransmission = prev.transmission_4;
      releaseTransmissionVersion = lib.getVersion releaseTransmission;
      # Track the release branch now that trackers allow 4.1.x, but fail
      # evaluation before accepting an unvetted 4.2.x+ daemon.
      guardedTransmission = withStandaloneSsoReauthentication (
        assert lib.asserts.assertMsg (
          lib.versionAtLeast releaseTransmissionVersion "4.1.0"
          && lib.versionOlder releaseTransmissionVersion "4.2.0"
        ) "Transmission must stay on the 4.1.x release series; got ${releaseTransmissionVersion}";
        releaseTransmission
      ) ./transmission-sso-reauthentication.patch "web/sso-reauth.test.cjs";
      lolekPackage = inputs.lolek.packages.${prev.system}.lolek;
      lolekYtDlp = prev.yt-dlp.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/yt-dlp-twitter-only-own-status-media.patch
        ];
      });
    in
    {
      inherit (pkgsNixpkgsUnstable) claude-code;

      bazarr =
        withStandaloneSsoReauthentication prev.bazarr ./bazarr-sso-reauthentication.patch
          "tests/sso-reauth.test.cjs";

      # https://github.com/NixOS/nixpkgs/pull/539100
      age-plugin-se = prev.age-plugin-se.overrideAttrs (old: {
        version = "0.2.1";
        src = prev.fetchFromGitHub {
          owner = "remko";
          repo = "age-plugin-se";
          tag = "v0.2.1";
          hash = "sha256-ga9EYfvscXf8VHSptjgnjaeZT+D/69PAr/s53JOHG20=";
        };
        postPatch = ''
          ${lib.optionalString (lib.versionAtLeast prev.swift.version "6") ''
            echo "age-plugin-se still applies patch-package-swift-legacy; remove or revisit this patch now that nixpkgs Swift is 6+."
            exit 1
          ''}
          make patch-package-swift-legacy
          ${old.postPatch}
          substituteInPlace Sources/Plugin.swift --replace-fail 'let createdAt = now.ISO8601Format()' 'let createdAt = ISO8601DateFormatter().string(from: now)'
        '';
      });

      # Pick up the latest window-management fixes ahead of the stable branch.
      inherit (pkgsNixpkgsUnstable) aerospace;

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
            url = "https://github.com/Mic92/nixpkgs-review/commit/efb00d8799c7d26e2ef7f6f827922e41106ed0a2.patch";
            hash = "sha256-jH4tnA1PIOU8BGkKetJXnBVggXe60kSRtvvKzKRjFVw=";
          })
        ];
      });

      # Preserve POST form data across an oauth2-proxy reauthentication. The
      # unconditional template patch is the expiry guard: if upstream changes
      # its integration point, the package build fails for an explicit review.
      searxng = prev.searxng.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./searxng-load-sso-reauth-script.patch ];

        doCheck = true;
        nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ prev.nodejs ];

        checkPhase = ''
          runHook preCheck
          ${lib.getExe prev.nodejs} --test tests/unit/client/sso-reauth.test.mjs
          runHook postCheck
        '';
      });

      lidarr = withServarrSsoReauthentication prev.lidarr;
      prowlarr = withServarrSsoReauthentication prev.prowlarr;
      radarr = withServarrSsoReauthentication prev.radarr;
      sonarr = withServarrSsoReauthentication prev.sonarr;

      # CI renders two-revision config diffs by calling standalone dix, not
      # nh's internal dix library. Stable dix 1.4.x omits the per-package size
      # deltas that nh 4.4's dix 2.x reports during activation, so keep the CLI
      # on unstable until the stable branch catches up.
      inherit (pkgsNixpkgsUnstable) dix;

      # Support Kubernetes 1.36 while carrying the nixpkgs update.
      # https://github.com/NixOS/nixpkgs/pull/539773
      kind = prev.kind.overrideAttrs (old: {
        version = "0.32.0";
        src = prev.fetchFromGitHub {
          owner = "kubernetes-sigs";
          repo = "kind";
          rev = "v0.32.0";
          hash = "sha256-ii0VhS1Nib+r2ZFIIkRvkcGY1fLxev6WnhbqvaZW7j8=";
        };
        patches = (old.patches or [ ]) ++ [
          # Fix apiserver connection loss after envoy lb container restart.
          (prev.fetchpatch {
            url = "https://github.com/kubernetes-sigs/kind/commit/9a24e6c1ae3d59f8de052ee5c3842820450a369a.patch";
            hash = "sha256-BP2Ub8b1GA7V0CGvhcoGuHRm7u+IMRTmN3mDc2rePnY=";
          })
        ];
      });

      inherit (pkgsNixpkgsUnstable) codex;

      lolek = lolekPackage.override { yt-dlp = lolekYtDlp; };

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

      # https://github.com/NixOS/nixpkgs/pull/545760
      telegram-bot-api =
        let
          nixpkgsVersion = lib.getVersion prev.telegram-bot-api;
        in
        assert lib.asserts.assertMsg (lib.versionAtLeast "10.2" nixpkgsVersion)
          "telegram-bot-api overlay is stale: nixpkgs has ${nixpkgsVersion}, newer than 10.2";
        prev.telegram-bot-api.overrideAttrs (_old: {
          version = "10.2";
          src = prev.fetchFromGitHub {
            owner = "tdlib";
            repo = "telegram-bot-api";
            # https://github.com/tdlib/telegram-bot-api/issues/783
            rev = "adfd7f6a8e990272851777eeb3ae0def4216f161";
            hash = "sha256-sICBisUDMirUOMN5ORQ2B9Wo8KC91hIn1sHyt2xClJ0=";
            fetchSubmodules = true;
          };
        });

      transmission_4 = guardedTransmission;
      transmission = guardedTransmission;

      # Fix XQuartz crashes under launchd socket activation and restore the
      # strictflexarrays1 hardening check.
      # https://github.com/NixOS/nixpkgs/pull/543662
      xorg-server =
        if prev.stdenv.hostPlatform.isDarwin then
          (prev.xorg-server.override {
            # Keep the patched xtrans private to XQuartz's xorg-server
            # dependency graph so unrelated X11 consumers do not rebuild.
            xtrans = prev.xtrans.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                (prev.fetchpatch {
                  url = "https://gitlab.freedesktop.org/xorg/lib/libxtrans/-/commit/79f6b0bfe2170496e8c37626043d009f4cd3f1e1.patch";
                  hash = "sha256-Y8QY1yAiOI/rSNi71/Qhsn6UEql556/pS2av7+vmGQA=";
                })
              ];
            });
          }).overrideAttrs
            (old: {
              hardeningDisable = lib.remove "strictflexarrays1" (old.hardeningDisable or [ ]);
            })
        else
          prev.xorg-server;

      # NixOS can expose the same D-Bus service file through both direct package
      # paths and system-path symlinks. Do not let dbus-broker report those
      # same-file duplicates at error level.
      # https://github.com/NixOS/nixpkgs/issues/303078
      dbus-broker = prev.dbus-broker.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/dbus-broker-ignore-duplicate-canonical-service-paths.patch
        ];
      });

      # Backport the partial rename chunk fix to the older Darwin package.
      # Applying it unconditionally there makes a future upgrade fail until
      # this backport is removed.
      diff-so-fancy =
        if prev.stdenv.hostPlatform.isDarwin then
          prev.diff-so-fancy.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              (prev.fetchpatch {
                url = "https://github.com/so-fancy/diff-so-fancy/commit/9a8b325a72de44d492b079a4b02cef4e2c33ab81.patch";
                hash = "sha256-v3sk7VjKMLO+aGMtWCyrI9DOy+LeyGAb25UrEX3oXbs=";
              })
            ];
          })
        else
          prev.diff-so-fancy;

      # Backport Grafana fix for /alerting/groups showing a bogus 404 header.
      # Upstream: https://github.com/grafana/grafana/pull/123286
      grafana = prev.grafana.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/grafana/grafana/pull/123286.patch";
            hash = "sha256-G9kIyw10aMq/SlSQ9kjdvZWtPFSwxIOnTygcaAmsHic=";
          })
        ];
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
        ];
      });

      open-webui = prev.open-webui.overridePythonAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/open-webui-apply-default-model-system-prompt.patch
        ];
      });

      # Track exact SAB cleanup artifacts at post-processing time so history
      # deletion can safely remove sorted outputs and temporary unpack trees
      # without carrying a private DB schema change.
      # https://github.com/sabnzbd/sabnzbd/issues/2754
      sabnzbd = withStandaloneSsoReauthentication (prev.sabnzbd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/booxter/sabnzbd/commit/2ee3243723ff613104f179167a8467025ec051b4.patch";
            hash = "sha256-anr7OPO3ZgW3PSaw32eNpkcAKa+SXonUQU+K11dc414=";
          })
        ];
      })) ./sabnzbd-sso-reauthentication.patch "tests/sso-reauth.test.cjs";

      vikunja = prev.vikunja.overrideAttrs (
        old:
        let
          frontend = old.passthru.frontend.overrideAttrs (frontendOld: {
            patches = (frontendOld.patches or [ ]) ++ [
              # TODO: send upstream.
              # Confirm label creation from the multiselect input.
              ../lib/patches/vikunja-confirm-label-creation.patch
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

      # Use the upstream macOS FSEvents switch for Attic to fix `watch-store`
      # reliability on Darwin while testing the async push issue locally.
      attic-client =
        if prev.stdenv.hostPlatform.isDarwin then
          prev.attic-client.overrideAttrs (
            old:
            let
              atticPatch = ../lib/patches/attic-client-use-fsevents.patch;
            in
            {
              patches = (old.patches or [ ]) ++ [ atticPatch ];
              cargoDeps = prev.rustPlatform.fetchCargoVendor {
                inherit (old) src;
                patches = [ atticPatch ];
                hash = "sha256-LqE4jOIasxIG4DAhgZJMlTSyt/a900QR06wBFtRNRO8=";
              };
            }
          )
        else
          prev.attic-client;

      # Torrent-client jobs can legitimately sit queued/checking without progress
      # or message churn for much longer than 5 minutes. Keep Shelfmark's stall
      # canceller for direct downloads, but do not auto-cancel torrent jobs.
      shelfmark = prev.shelfmark.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/shelfmark-disable-torrent-stall-cancel.patch
          ../lib/patches/shelfmark-add-download-poll-debug-state.patch
          ../lib/patches/shelfmark-add-download-diagnostic-signal.patch
          ../lib/patches/shelfmark-add-throttled-poll-heartbeat-logs.patch
        ];
      });
    };
}
