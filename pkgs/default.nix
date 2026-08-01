# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps pkgs;
  degoogPackage = pkgs.callPackage ./degoog { };
  gitPrecomposePatch = ../lib/patches/git-precompose-utf8-flex-array.patch;
  # Keep this as opt-in packages instead of overriding pkgs.git globally: Git
  # is a common build tool, so a global override can fan out into many rebuilds.
  patchGitPrecompose =
    gitPackage:
    gitPackage.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        gitPrecomposePatch
      ];
    });
in
{
  degoog = degoogPackage;

  degoog-official-extensions = pkgs.callPackage ./degoog/official-extensions.nix {
    degoogNodeModules = degoogPackage.productionNodeModules;
  };

  degoog-stackexchange-engine = pkgs.callPackage ./degoog/stackexchange-engine.nix { };

  firefox-devtools-mcp = pkgs.callPackage ./firefox-devtools-mcp { };

  gitDarwinPrecompose =
    if pkgs.stdenv.hostPlatform.isDarwin then patchGitPrecompose pkgs.git else pkgs.git;

  gitMinimalDarwinPrecompose =
    if pkgs.stdenv.hostPlatform.isDarwin then patchGitPrecompose pkgs.gitMinimal else pkgs.gitMinimal;

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  pki-rotation = pkgs.callPackage ./pki-rotation {
    issueInternalServiceCert = appPackages.issue-internal-service-cert;
    issueObservabilityCert = appPackages.issue-observability-cert;
  };
}
