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

      pkgsLldb = getPkgs inputs.debugserver;
      pkgsNixpkgsUnstable = getPkgs inputs.nixpkgs-unstable;
      pkgsXquartzPr = getPkgs inputs.nixpkgs-xquartz-pr;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      releaseTransmission = prev.transmission_4;
      releaseTransmissionVersion = lib.getVersion releaseTransmission;
      # Track the release branch now that trackers allow 4.1.x, but fail
      # evaluation before accepting an unvetted 4.2.x+ daemon.
      guardedTransmission =
        assert lib.asserts.assertMsg (
          lib.versionAtLeast releaseTransmissionVersion "4.1.0"
          && lib.versionOlder releaseTransmissionVersion "4.2.0"
        ) "Transmission must stay on the 4.1.x release series; got ${releaseTransmissionVersion}";
        releaseTransmission;
      lolekPackage = inputs.lolek.packages.${prev.system}.lolek;
      lolekYtDlp = prev.yt-dlp.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/yt-dlp-twitter-only-own-status-media.patch
        ];
      });
    in
    {
      inherit (llmAgentsPkgs) claude-code;
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

      # Carry recursive Codex project trust until openai/codex#19426 lands.
      # Also load user-local config.local.toml so CLI config writes avoid
      # Home Manager's read-only config.toml symlink.
      # Recursive trust patch from https://github.com/luisnquin/nixos-config/commit/1859865c1db5e318635326787d04333b07054b26
      codex = llmAgentsPkgs.codex.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/codex-recursive-project-trust.patch
          ../lib/patches/codex-user-config-local-overlay.patch
        ];
      });

      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      lolek = lolekPackage.override {
        yt-dlp = lolekYtDlp;
      };

      transmission_4 = guardedTransmission;
      transmission = guardedTransmission;

      xquartz = pkgsXquartzPr.xquartz;

      # NixOS can expose the same D-Bus service file through both direct package
      # paths and system-path symlinks. Do not let dbus-broker report those
      # same-file duplicates at error level.
      # https://github.com/NixOS/nixpkgs/issues/303078
      dbus-broker = prev.dbus-broker.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/dbus-broker-ignore-duplicate-canonical-service-paths.patch
        ];
      });

      # Carry the partial rename chunk fix until it lands upstream.
      # TODO: report upstream and drop this extra patch once it is released.
      diff-so-fancy = prev.diff-so-fancy.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/booxter/diff-so-fancy/commit/e9d375a3730366deb3d395dd693da86ad11e3368.patch";
            hash = "sha256-3kI5fYOycVMub7sHrJnQfIZtKC026TpQIGSb4NCpreg=";
          })
        ];
      });

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

      # Track exact SAB cleanup artifacts at post-processing time so history
      # deletion can safely remove sorted outputs and temporary unpack trees
      # without carrying a private DB schema change.
      # https://github.com/sabnzbd/sabnzbd/issues/2754
      sabnzbd = prev.sabnzbd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/booxter/sabnzbd/commit/2ee3243723ff613104f179167a8467025ec051b4.patch";
            hash = "sha256-anr7OPO3ZgW3PSaw32eNpkcAKa+SXonUQU+K11dc414=";
          })
        ];
      });

      vikunja = prev.vikunja.overrideAttrs (
        old:
        let
          frontend = old.passthru.frontend.overrideAttrs (frontendOld: {
            patches = (frontendOld.patches or [ ]) ++ [
              # Focus the quick-actions input when its modal opens.
              (prev.fetchpatch {
                url = "https://github.com/go-vikunja/vikunja/commit/01fff665c60e2b25e65205f706845517881db149.patch";
                stripLen = 1;
                hash = "sha256-79N56esq0esenvoFfai9klv5x17sCQ2qC2JeuSgXe6I=";
              })
              # TODO: send upstream.
              # Confirm label creation from the multiselect input.
              (prev.fetchpatch {
                url = "https://github.com/booxter/vikunja/commit/5ce44564b395bfc3edb3895074b625e7a517e764.patch";
                stripLen = 1;
                hash = "sha256-6BWLcSTiK65OvwB+LAVmwhXpiHc6O031aSK1vAvk7sk=";
              })
            ];
          });
        in
        {
          patches = (old.patches or [ ]) ++ [
            # Drop when https://github.com/go-vikunja/vikunja/pull/2811 reaches nixpkgs.
            ../lib/patches/vikunja-user-count-metrics-event-dispatch.patch
          ];
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
