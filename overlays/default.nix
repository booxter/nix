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

      pkgs = getPkgs inputs.nixpkgs;
      pkgsLldb = getPkgs inputs.debugserver;
      pkgsRamalama = getPkgs inputs.nixpkgs-ramalama;
      pkgsTelegramDesktop = getPkgs inputs.nixpkgs-telegram-desktop;
      pkgsTransmission = getPkgs inputs.nixpkgs-transmission;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      pinnedTransmission = pkgsTransmission.transmission_4;
      patchedTransmission = pinnedTransmission.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # Prefer selected trackers once their announces are already due,
          # without changing tracker-provided announce cadence.
          (prev.fetchpatch {
            url = "https://github.com/booxter/transmission/commit/7c93a460601cb2a2b2653f11144c321d49f39931.patch";
            hash = "sha256-IOixkw06k0OFrnb0vE2V9+UxRlFjtR6ntsBNS8IKpBo=";
          })
        ];
      });
      isMainNixpkgs = prev.lib.version == pkgs.lib.version;
    in
    {
      inherit (llmAgentsPkgs) codex claude-code;

      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
      inherit (pkgs) netbootxyz-efi;

      inherit (pkgs) readarr sonarr;
      ramalama = if prev.stdenv.hostPlatform.isDarwin then pkgsRamalama.ramalama else prev.ramalama;
      telegram-desktop =
        if prev.stdenv.hostPlatform.isDarwin then
          pkgsTelegramDesktop.telegram-desktop
        else
          prev.telegram-desktop;
      transmission_4 = patchedTransmission;
      transmission = patchedTransmission;

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
          # Ignore stale playback callbacks after the original session is gone.
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/fa992be8f438d7cce1d8d8d3a0b534e7309e6dc7.patch";
            hash = "sha256-Vq0oFhaLwt6Oweq+xnIsIg3vJPgQb7G32MBDg0IPPUo=";
          })
          # Clear orphaned transcode progress instead of flipping it to direct play.
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/070f0919d1130c3ce5729f87700e2b6b23483bf0.patch";
            hash = "sha256-4UXJ2Ut9yXEL5JXpNVqaUw++X7iC7terL/WywA5MQXQ=";
          })
        ];
      });

      # Carry local fixes for broken user-count metrics until upstream releases them.
      vikunja = prev.vikunja.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/vikunja-user-count-metrics-event-dispatch.patch
        ];
      });

      kitty =
        if isMainNixpkgs then
          # Carry the upstream fix for paused-rendering selection crashes until it lands.
          prev.kitty.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              (prev.fetchpatch {
                url = "https://github.com/kovidgoyal/kitty/commit/774b9af9e36181ef68163adc31eeda56e6154666.patch";
                hash = "sha256-QwPdnxiY7hMzSpAi7yRKXsW1Ew8AX/4Rr2Phx6Kj1mo=";
              })
            ];
          })
        else
          prev.kitty;
    };
}
