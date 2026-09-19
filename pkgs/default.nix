# You can build them using 'nix build .#example'
pkgs:
let
  appPackages = import ../apps/packages.nix { inherit pkgs; };
  atomicFileWrites = pkgs.python3Packages.callPackage ./atomic-file-writes {
    inherit (pkgs) pythonRuffCheckHook;
  };
  gitCommandRunner = pkgs.python3Packages.callPackage ./git-command-runner {
    inherit (pkgs) pythonRuffCheckHook;
  };
  radarrRepairContracts = pkgs.callPackage ./radarr-repair/contracts.nix { };
  radarrRepairGoModels = pkgs.callPackage ./radarr-repair/go-models.nix {
    contracts = radarrRepairContracts;
  };
  radarrRepairPydanticModels = pkgs.callPackage ./radarr-repair/pydantic-models.nix {
    contracts = radarrRepairContracts;
  };
  radarrRepair = pkgs.callPackage ./radarr-repair {
    goModels = radarrRepairGoModels;
    mkvtoolnixCli = pkgs.mkvtoolnix-cli;
  };
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

  nix-builder-metrics = pkgs.callPackage ./nix-builder-metrics {
    inherit atomicFileWrites;
  };

  postgresql-role-password = pkgs.callPackage ./postgresql-role-password { };

  pythonRuffCheckHook = pkgs.callPackage ./python-ruff-check-hook { };

  radarr-repair = radarrRepair.controller;

  radarr-repair-worker = radarrRepair.worker;

  radarr-repair-planner = pkgs.callPackage ./radarr-repair-planner {
    contracts = radarrRepairContracts;
    pydanticModels = radarrRepairPydanticModels;
  };

  radarr-repair-contracts = radarrRepairContracts;

  radarr-repair-go-models = radarrRepairGoModels;

  storage-observability = pkgs.callPackage ./storage-observability {
    inherit atomicFileWrites;
  };
}
