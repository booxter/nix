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
      pkgsRelease = getPkgs inputs.nixpkgs-25_11;
      pkgsTransmission = getPkgs inputs.nixpkgs-transmission;
      pkgsDiffSoFancy = getPkgs inputs.nixpkgs-diff-so-fancy;
      pkgsFirefoxUnwrapped = getPkgs inputs.nixpkgs-firefox-unwrapped;
      pkgsThunderbirdUnwrapped = getPkgs inputs.nixpkgs-thunderbird-unwrapped;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      pinnedTransmission = pkgsTransmission.transmission_4;
      getPackageVersion =
        nixpkgsInput: packagePath:
        let
          pkgFile = builtins.readFile (nixpkgsInput + packagePath);
          versionLine = prev.lib.findFirst (line: prev.lib.hasInfix "version = " line) null (
            prev.lib.splitString "\n" pkgFile
          );
          match = builtins.match ".*version = \"([^\"]+)\".*" (
            if versionLine == null then "" else versionLine
          );
        in
        if match == null then
          throw "Failed to extract version from ${packagePath}"
        else
          builtins.head match;
      nixpkgsDiffSoFancyVersion = getPackageVersion inputs.nixpkgs "/pkgs/by-name/di/diff-so-fancy/package.nix";
    in
    if prev.lib.versionAtLeast nixpkgsDiffSoFancyVersion "1.4.10" then
      throw ''
        Temporary nixpkgs-diff-so-fancy override is stale: nixpkgs already provides diff-so-fancy ${nixpkgsDiffSoFancyVersion}.
        Remove the nixpkgs-diff-so-fancy input and the corresponding diff-so-fancy overlay entry.
      ''
    else
      {
        inherit (llmAgentsPkgs) codex claude-code;

        # https://github.com/NixOS/nixpkgs/pull/374846
        inherit (pkgsLldb) debugserver;

        # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
        inherit (pkgs) netbootxyz-efi;

        # Pull Sonarr/Readarr from release-25.11 and pin Transmission via a dedicated nixpkgs input.
        # TODO: report issues; investigate; fix
        inherit (pkgsRelease) readarr sonarr;
        transmission_4 = pinnedTransmission;
        transmission = pinnedTransmission;

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

        # Carry nixpkgs PR #508799 until it lands in the pinned nixpkgs input.
        inherit (pkgsDiffSoFancy) diff-so-fancy;
      }
      // inputs.nixpkgs.lib.optionalAttrs prev.stdenv.isDarwin {
        inherit (pkgsFirefoxUnwrapped) firefox-unwrapped;
        inherit (pkgsThunderbirdUnwrapped) thunderbird-unwrapped;

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
