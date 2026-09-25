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
  mediaRepairContracts = pkgs.callPackage ./media-repair/contracts.nix { };
  mediaRepairGoModels = pkgs.callPackage ./media-repair/go-models.nix {
    contracts = mediaRepairContracts;
  };
  mediaRepairPydanticModels = pkgs.callPackage ./media-repair/pydantic-models.nix {
    contracts = mediaRepairContracts;
  };
  mediaRepair = pkgs.callPackage ./media-repair {
    goModels = mediaRepairGoModels;
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

  lidarr-repair = mediaRepair.lidarrController;

  media-repair-contracts = mediaRepairContracts;

  media-repair-go-models = mediaRepairGoModels;

  media-repair-planner = pkgs.callPackage ./media-repair-planner {
    contracts = mediaRepairContracts;
    pydanticModels = mediaRepairPydanticModels;
  };

  media-repair-review = mediaRepair.review;

  media-repair-worker = mediaRepair.worker;

  nix-builder-metrics = pkgs.callPackage ./nix-builder-metrics {
    inherit atomicFileWrites;
  };

  postgresql-role-password = pkgs.callPackage ./postgresql-role-password { };

  pythonRuffCheckHook = pkgs.callPackage ./python-ruff-check-hook { };

  radarr-repair = mediaRepair.controller;

  storage-observability = pkgs.callPackage ./storage-observability {
    inherit atomicFileWrites;
  };
}
