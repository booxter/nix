{
  lib,
  nix,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
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
  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--set NIXPKGS_CACHE_WARMER_NIX_INSTANTIATE ${lib.getExe' nix "nix-instantiate"}"
    "--set NIXPKGS_CACHE_WARMER_INVENTORY_EXPR ${./inventory.nix}"
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
