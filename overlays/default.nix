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
      pkgsFirefoxUnwrapped = getPkgs inputs.nixpkgs-firefox-unwrapped;
      pkgsThunderbirdUnwrapped = getPkgs inputs.nixpkgs-thunderbird-unwrapped;
      llmAgentsPkgs = inputs.llm-agents.packages.${prev.system};
      pinnedTransmission = pkgsTransmission.transmission_4;
    in
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
          # fix directors not populated for new movies since 10.11.6
          (prev.fetchpatch {
            url = "https://github.com/jellyfin/jellyfin/commit/673f617994da6ff6a45cf428a3ea47de59edc6c5.patch";
            hash = "sha256-iHriDqPqJ5Xcdrq905sdSxMmEvr4hWmNrzU5CDFFJyY=";
          })
        ];
      });
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
