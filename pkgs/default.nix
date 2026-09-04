# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps/packages.nix { inherit pkgs; };
  atomicFileWrites = pkgs.python3Packages.callPackage ./atomic-file-writes { };
  gitCommandRunner = pkgs.python3Packages.callPackage ./git-command-runner { };
in
{
  aiosqlitepool = pkgs.callPackage ./aiosqlitepool { };

  atomic-file-writes = atomicFileWrites;

  codex-mcp-login = pkgs.callPackage ./codex-mcp-login { };

  firefox-devtools-mcp = pkgs.callPackage ./firefox-devtools-mcp { };

  firefox-migrate-app-data = pkgs.callPackage ./firefox-migrate-app-data { };

  get-ff-cookie = appPackages.get-ff-cookie;

  flake-input-update-summary = pkgs.callPackage ./flake-input-update-summary { };

  git-command-runner = gitCommandRunner;

  join-media-parts = pkgs.callPackage ./join-media-parts { };

  nix-builder-metrics = pkgs.callPackage ./nix-builder-metrics {
    inherit atomicFileWrites;
  };

  postgresql-role-password = pkgs.callPackage ./postgresql-role-password { };

  pythonRuffCheckHook = pkgs.callPackage ./python-ruff-check-hook { };

  storage-observability = pkgs.callPackage ./storage-observability {
    inherit atomicFileWrites;
  };
}
