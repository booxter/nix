# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps/packages.nix { inherit pkgs; };
  atomicFileWrites = pkgs.python3Packages.callPackage ./atomic-file-writes { };
  gitCommandRunner = pkgs.python3Packages.callPackage ./git-command-runner { };
in
{
  aiosqlitepool = pkgs.callPackage ./aiosqlitepool { };

  debugserver = pkgs.callPackage ./debugserver { };

  atomic-file-writes = atomicFileWrites;

  firefox-devtools-mcp = pkgs.callPackage ./firefox-devtools-mcp { };

  get-ff-cookie = appPackages.get-ff-cookie;

  flake-input-update-summary = pkgs.callPackage ./flake-input-update-summary { };

  git-command-runner = gitCommandRunner;

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  postgresql-role-password = pkgs.callPackage ./postgresql-role-password { };

  storage-observability = pkgs.callPackage ./storage-observability {
    inherit atomicFileWrites;
  };
}
