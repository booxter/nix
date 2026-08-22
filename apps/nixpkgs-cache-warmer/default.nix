{
  attic-client,
  lib,
  nix,
  openssh,
  python3,
  runnerHost ? "",
  ruff,
}:
let
  pythonPackages = python3.pkgs;
  atomicFileWrites = pythonPackages.callPackage ../../pkgs/atomic-file-writes { };
in
pythonPackages.buildPythonApplication {
  pname = "nixpkgs-cache-warmer";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--set NIXPKGS_CACHE_WARMER_ATTIC ${lib.getExe attic-client}"
    "--set NIXPKGS_CACHE_WARMER_NIX ${lib.getExe nix}"
    "--set NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE ${lib.getExe' nix "nix-instantiate"}"
    "--set NIXPKGS_CACHE_WARMER_INVENTORY_EXPR ${./inventory.nix}"
    "--set NIXPKGS_CACHE_WARMER_STATE_FILE /var/lib/nixpkgs-cache-warmer/status.json"
    "--set NIXPKGS_CACHE_WARMER_RUNNER ${lib.escapeShellArg runnerHost}"
    "--set NIXPKGS_CACHE_WARMER_SSH ${lib.getExe openssh}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/nixpkgs_cache_warmer
  '';

  pythonImportsCheck = [ "nixpkgs_cache_warmer" ];

  meta = {
    description = "Build maintained nixpkgs packages and publish them to Attic";
    license = lib.licenses.mit;
    mainProgram = "nixpkgs-cache-warmer";
    platforms = lib.platforms.unix;
  };
}
