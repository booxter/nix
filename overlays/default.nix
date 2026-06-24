{ inputs, ... }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications =
    final: prev:
    let
      getPkgs =
        np:
        import np {
          inherit (prev) system;
          config = {
            allowUnfree = true;
          };
        };

      pkgsLldb = getPkgs inputs.debugserver;
      pkgsTransmission = getPkgs inputs.nixpkgs-transmission;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      pinnedTransmission = pkgsTransmission.transmission_4;
      lolekPackage = inputs.lolek.packages.${prev.system}.lolek;
      lolekYtDlp = prev.yt-dlp.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/yt-dlp-twitter-only-own-status-media.patch
        ];
      });
      patchedTransmission = pinnedTransmission.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Fix the 4.0.6 HTTP announce bug where a later failed sibling
          # response could overwrite an earlier successful announce.
          # Upstream: https://github.com/transmission/transmission/pull/7086
          (prev.fetchpatch {
            url = "https://github.com/transmission/transmission/commit/036174aa0e3d1f878e2a629ffe3709942a947c06.patch";
            hash = "sha256-VekP2wwynCFX8QE3g1Eb1rynRPR+AZDnfR2ey9i3yJs=";
          })
        ];
      });
    in
    {
      inherit (llmAgentsPkgs) codex claude-code;

      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      lolek = lolekPackage.override {
        yt-dlp = lolekYtDlp;
      };

      transmission_4 = patchedTransmission;
      transmission = patchedTransmission;

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

      # Backport Open WebUI 0.9.5 web-search fix: SafeWebBaseLoader passed
      # allow_redirects twice to aiohttp, so all fetched SearXNG result pages
      # were skipped and chats saw "No sources found".
      # Upstream: https://github.com/open-webui/open-webui/pull/24874
      open-webui = prev.open-webui.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/open-webui/open-webui/pull/24874.patch";
            hash = "sha256-7xgftGzUj0qHAId8+hHYAC0dhif5PVS0YClWHImAuJ8=";
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

      # Carry local fixes for broken user-count metrics until upstream releases them.
      vikunja = prev.vikunja.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/vikunja-user-count-metrics-event-dispatch.patch
        ];
      });

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
