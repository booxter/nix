{ inputs }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications =
    final: prev:
    let
      inherit (prev) lib;
      system = prev.stdenv.hostPlatform.system;
      # Use the same Nix toolchain on hosts with a separate Proxmox base.
      releasePkgs = inputs.nixpkgs.legacyPackages.${system};
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
        releaseTransmission.overrideAttrs (old: {
          # Keep 128 torrent files open across bursts of NFS I/O on srvarr.
          patches = (old.patches or [ ]) ++ [ ../patches/transmission-open-file-limit.patch ];
        })
      );
    in
    {
      # Keep the interactive clients, including Codex, on the latest packaged releases.
      inherit (pkgsNixpkgsUnstable)
        chatgpt
        claude-code
        mcp-nixos
        zoom-us
        ;

      attic-client = prev.attic-client.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Drop when the packaged client honors NIX_SSL_CERT_FILE.
          (
            if lib.versionAtLeast old.version "0-unstable-2026-07-06" then
              ../patches/attic-client-honor-nix-ssl-cert-file-reqwest-0.13.patch
            else
              ../patches/attic-client-honor-nix-ssl-cert-file.patch
          )
        ];
      });

      codex = pkgsNixpkgsUnstable.codex.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # https://github.com/openai/codex/issues/47390
          ../patches/codex-show-full-patches.patch
          # Include context tokens and session throughput using server response timings.
          ../patches/codex-context-tokens.patch
          # Show current-turn tokens and completion throughput.
          ../patches/codex-turn-tokens.patch
          # Retry capacity errors without server advice within the existing retry budget.
          ../patches/codex-capacity-retry.patch
          # Allow ten stream retries by default.
          ../patches/codex-stream-retry-limit.patch
          # Name checkout directories with /worktree <name>; keep managed hash buckets.
          # https://github.com/openai/codex/issues/38326
          ../patches/codex-named-worktrees.patch
          # F10 mutes spoken replies while keeping the microphone live.
          # Adapted from https://github.com/FrostBy/agent-kit/releases/tag/v0.6.2
          ../patches/codex-mute-agent-speaker.patch
        ];
      });

      sops-with-age-askpass = prev.sops.overrideAttrs (old: {
        # User services need a graphical PIN prompt. Drop when SOPS supports it.
        patches = (old.patches or [ ]) ++ [ ../patches/sops-use-askpass-for-age-pins.patch ];
        preCheck = (old.preCheck or "") + ''
          go test ./age ./keyservice
        '';
      });

      sops-install-secrets-with-keyservice =
        let
          inherit (import inputs.sops-nix { pkgs = final; }) sops-install-secrets;
        in
        sops-install-secrets.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ../patches/sops-install-secrets-decrypt-with-remote-keyservice.patch
          ];
          # The full installer suite needs root. The remote decryption tests run as a user.
          doCheck = true;
          __darwinAllowLocalNetworking = true;
          checkPhase = ''
            runHook preCheck
            export TEST_ASSETS="$PWD/pkgs/sops-install-secrets/test-assets"
            go test ./pkgs/sops-install-secrets -run '^TestRemoteDecryption' -count=1
            runHook postCheck
          '';
        });

      openssh-yubikey = prev.openssh.overrideAttrs (old: {
        pname = "openssh-yubikey";
        patches = (old.patches or [ ]) ++ [
          ../patches/openssh-restore-touch-prompt-after-pin.patch
          (prev.replaceVars ../patches/openssh-resolve-signing-device.patch { resolver = final.ssh-device; })
          (prev.replaceVars ../patches/openssh-prompt-for-pin-before-touch.patch {
            resolver = final.ssh-device;
          })
        ];
      });

      cuetools = prev.cuetools.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Prevent malformed timestamps from overflowing the output buffer.
          # https://github.com/svend/cuetools/pull/44
          ../patches/cuetools-prevent-time-frame-buffer-overflow.patch
        ];
      });

      gpauth = prev.gpauth.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/gpclient-3-browser-listen.patch ];
      });

      gpclient = (prev.gpclient.override { gpauth = final.gpauth; }).overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/gpclient-3-browser-listen.patch ];
      });

      nix = releasePkgs.nixVersions.latest.appendPatches [
        # Avoid inheriting a locked signal callback registry in daemon workers.
        ../patches/nix-reset-signal-callbacks-after-fork.patch
        # Don't block the worker in goal cleanup on a substitution thread that
        # may be waiting for the GC lock held by a build hook whose stderr the
        # worker drains.
        ../patches/nix-do-not-join-substitution-thread.patch
      ];

      inherit (releasePkgs) nix-output-monitor;

      jiratui = prev.jiratui.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/jiratui-fetch-all-projects.patch
          ../patches/jiratui-normalize-jql-expression-ids.patch
        ];
      });

      paperless-ngx = prev.paperless-ngx.overrideAttrs (old: {
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
          # TODO: report upstream. Real sleeps can exceed the 100 ms stability
          # delay for both files, returning two stable files when one is expected.
          "src/documents/tests/test_management_consumer.py::TestFileStabilityTracker::test_multiple_files_tracking"
        ];
      });

      lidarr = prev.lidarr.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Artist and album refreshes reconcile the same releases and tracks.
          ../patches/lidarr-serialize-refresh-children.patch
          # Restore queue associations from grab titles, not import-failure folder names.
          ../patches/lidarr-use-grab-history-for-ambiguous-title.patch
          # Reject unidentified queue removal without crashing or reporting success.
          # https://github.com/Lidarr/Lidarr/issues/5732
          ../patches/lidarr-reject-unidentified-queue-removal.patch
        ];
      });

      lsdvd = prev.lsdvd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/lsdvd-expose-title-continuations.patch
          ../patches/lsdvd-expose-equivalent-titles.patch
        ];
      });

      # Avoid the HTTP idle timeout race that drops Prometheus alert deliveries.
      # https://github.com/NixOS/nixpkgs/pull/593476
      prometheus-alertmanager =
        assert lib.asserts.assertMsg (lib.versionOlder prev.prometheus-alertmanager.version "0.35.1")
          "Remove the prometheus-alertmanager override: nixpkgs now includes 0.35.1 or newer";
        prev.prometheus-alertmanager.overrideAttrs (finalAttrs: {
          version = "0.35.1";
          src = prev.fetchFromGitHub {
            owner = "prometheus";
            repo = "alertmanager";
            tag = "v${finalAttrs.version}";
            hash = "sha256-PGGZCdamxZjsINnVxbHQZQ0uJ93XVn+7f6mOvDTX3Sg=";
          };
        });

      # Expose Radarr's stable manual-import rejection reason beside its human
      # message so local API consumers do not have to match mutable text.
      radarr = prev.radarr.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/radarr-expose-import-rejection-reason.patch
          # Refresh rewrites related rows through non-atomic read/diff/write steps.
          ../patches/radarr-serialize-movie-refreshes.patch
          ../patches/radarr-use-grab-history-for-ambiguous-title.patch
        ];
      });

      sonarr = prev.sonarr.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/sonarr-serialize-episode-refreshes.patch ];
      });

      romm = prev.romm.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/romm-zip-cache-permissions.patch
        ];
      });

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

      lolek =
        let
          lolekPackage = inputs.lolek.packages.${system}.lolek;
          lolekYtDlp = prev.yt-dlp.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ../patches/yt-dlp-twitter-only-own-status-media.patch
            ];
          });
        in
        lolekPackage.override { yt-dlp = lolekYtDlp; };

      reframe = prev.reframe.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Drop once upstream retries connector discovery after waking displays.
          # https://github.com/AlynxZhou/reframe/issues/42
          ../patches/reframe-wait-for-connector.patch
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
        patches = (old.patches or [ ]) ++ [
          ../patches/jellyfin-refresh-artwork-on-movie-change.patch
          # Jellyfin 12 still leaves disposed-session errors unhandled in the close callback.
          # Upstream: https://github.com/jellyfin/jellyfin/issues/16512
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/c64abc489e.patch";
            hash = "sha256-/Y2QiBkeLY4Wi+RlgFcNuzLPuwOF1sRyf7hnBuUEzAM=";
          })
        ];
      });

      sabnzbd = prev.sabnzbd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/sabnzbd-cancel-multiple-par2-sets.patch
          ../patches/sabnzbd-publish-connection-before-connect.patch
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

      shelfmark = prev.shelfmark.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          PYTHONPYCACHEPREFIX="$TMPDIR/shelfmark-pycache" \
            ${prev.python314}/bin/python -m compileall -q shelfmark
        '';
        patchFlags = [
          "-p1"
          "-l"
        ];
        patches = (old.patches or [ ]) ++ [
          # Persist external-client download IDs and reattach to them after
          # Shelfmark restarts, without resolving an expired indexer URL.
          ../patches/shelfmark-resume-external-downloads.patch
          # Torrent-client jobs can legitimately sit queued/checking without
          # progress or message churn for much longer than 5 minutes. Keep
          # Shelfmark's stall canceller for direct downloads, but do not
          # auto-cancel torrent jobs.
          ../patches/shelfmark-disable-torrent-stall-cancel.patch
          ../patches/shelfmark-retry-transmission-connectivity.patch
          ../patches/shelfmark-add-download-poll-debug-state.patch
          ../patches/shelfmark-add-download-diagnostic-signal.patch
          ../patches/shelfmark-add-throttled-poll-heartbeat-logs.patch
          ../patches/shelfmark-redact-sabnzbd-api-key.patch
          ../patches/shelfmark-truncate-filenames-bytes.patch
          ../patches/shelfmark-release-room-lock-before-emit.patch
        ];
      });
    };
}
