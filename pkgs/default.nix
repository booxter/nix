# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps/packages.nix pkgs;
  atomicFileWrites = pkgs.python3Packages.callPackage ./atomic-file-writes { };
  gitCommandRunner = pkgs.python3Packages.callPackage ./git-command-runner { };
  hostInventory = import ../lib/inventory { inherit (pkgs) lib; };
  pkiCertificates = appPackages.issue-internal-service-cert;
  sopsTools = import ../apps/sops/package.nix {
    inherit hostInventory pkgs;
  };
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
  debugserver = pkgs.callPackage ./debugserver { };

  atomic-file-writes = atomicFileWrites;

  firefox-devtools-mcp = pkgs.callPackage ./firefox-devtools-mcp { };

  get-ff-cookie = appPackages.get-ff-cookie;

  flake-input-update-summary = pkgs.callPackage ./flake-input-update-summary { };

  gitDarwinPrecompose =
    if pkgs.stdenv.hostPlatform.isDarwin then patchGitPrecompose pkgs.git else pkgs.git;

  gitMinimalDarwinPrecompose =
    if pkgs.stdenv.hostPlatform.isDarwin then patchGitPrecompose pkgs.gitMinimal else pkgs.gitMinimal;

  git-command-runner = gitCommandRunner;

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  issue-proxmox-exporter-token = appPackages.issue-proxmox-exporter-token;

  patch-context = pkgs.callPackage ./patch-context { };

  pki-certificates = pkiCertificates;

  pki-rotation = pkgs.callPackage ./pki-rotation {
    inherit
      atomicFileWrites
      gitCommandRunner
      pkiCertificates
      sopsTools
      ;
  };

  postgresql-role-password = pkgs.callPackage ./postgresql-role-password { };

  sops-tools = sopsTools;
}
