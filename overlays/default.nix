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
        src = prev.fetchFromGitHub {
          owner = "booxter";
          repo = "transmission";
          rev = "b9c08a7d3daf1577f20d22c49b14624eb14cc7a6";
          hash = "sha256-GBLQ7ns/veoRiVEXxDgaWrx5te7RE6UKFuNkTEVaPOk=";
          fetchSubmodules = true;
        };
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
      mesa =
        if prev.stdenv.hostPlatform.isDarwin then
          prev.mesa.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              # Carry the Darwin timeout fix from nixpkgs PR #519195 until
              # the pinned nixpkgs input picks it up.
              # Darwin only installs `swrast_dri.so`; stop waiting for a
              # nonexistent `.dylib` name in the megadriver install script.
              substituteInPlace bin/install_megadrivers.py \
                --replace-fail "            while ext != '.' + args.libname_suffix" "            while ext != '.so'"

              # Darwin uses `st_mtimespec` instead of `st_mtim`.
              substituteInPlace src/gallium/drivers/llvmpipe/lp_context.c \
                --replace-fail 'st_mtim.' 'st_mtimespec.'
            '';
          })
        else
          prev.mesa;
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
          # Ignore stale progress updates unless transcode job exists.
          (prev.fetchpatch {
            url = "https://github.com/booxter/jellyfin/commit/3b63ec92420305d24e0fe90a452f0cdcbb624872.patch";
            hash = "sha256-X5qv8+R2s/zk411gQHyNhRaf9VRFSG+47W8Fy0N+96U=";
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
