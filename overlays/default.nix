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
      pkgsMaster = getPkgs inputs.nixpkgs-master;
      pkgsTransmission = getPkgs inputs.nixpkgs-transmission;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      pinnedTransmission = pkgsTransmission.transmission_4;
    in
    {
      inherit (llmAgentsPkgs) codex claude-code;

      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
      inherit (pkgs) netbootxyz-efi;

      inherit (pkgs) readarr sonarr;
      transmission_4 = pinnedTransmission;
      transmission = pinnedTransmission;

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
        ];
      });

      # Carry local fixes for broken user-count metrics until upstream releases them.
      vikunja = prev.vikunja.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../lib/patches/vikunja-user-count-metrics-event-dispatch.patch
        ];
      });
    }
    // inputs.nixpkgs.lib.optionalAttrs prev.stdenv.isDarwin {
      # Carry nixpkgs PR #509497 until it lands in the pinned nixpkgs input.
      inherit (pkgsMaster) vscode;
      inherit (pkgsMaster) code-cursor;

      # Mirror nixpkgs PR #501885 on Darwin without pulling a separate nixpkgs input.
      # This is a local attempt to fix the Kitty crashes I am seeing on macOS.
      kitty = prev.kitty.overrideAttrs (
        old:
        let
          version = "0.46.2";
          src = prev.fetchFromGitHub {
            owner = "kovidgoyal";
            repo = "kitty";
            tag = "v${version}";
            hash = "sha256-x+jBQrg3Iaj6PLMF1hIjS46odxv5GxPMcvC9JddYCHo=";
          };
        in
        {
          inherit version src;
          patches = (old.patches or [ ]) ++ [
            ../lib/patches/kitty-paused-rendering-selection.patch
          ];
          goModules =
            (prev.buildGo126Module {
              pname = "kitty-go-modules";
              inherit src version;
              vendorHash = "sha256-FaSWBeQJlvw9vXcHJ/OaFd48K8d7X86X8w7wpG84Ltw=";
            }).goModules;
        }
      );
    };
}
