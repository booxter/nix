{ pkgs }:
let
  pythonPackages = pkgs.python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "package-update-tools";
  version = "0.1.0";
  pyproject = true;

  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    natsort
    pydantic
    semantic-version
  ];

  nativeCheckInputs = with pythonPackages; [
    pkgs.ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    # passthru.updateScript remains an external executable interface. Preserve
    # its historical tool surface until individual package updaters migrate.
    "--prefix PATH : ${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.git
        pkgs.gnused
        pkgs.jq
        pkgs.nix
        pkgs.nix-update
        pkgs.prefetch-npm-deps
      ]
    }"
    "--set PACKAGE_UPDATES_COSIGN ${pkgs.lib.getExe pkgs.cosign}"
    "--set PACKAGE_UPDATES_NIX ${pkgs.lib.getExe pkgs.nix}"
    "--set PACKAGE_UPDATES_NIX_PREFETCH_DOCKER ${pkgs.lib.getExe pkgs.nix-prefetch-docker}"
    "--set PACKAGE_UPDATES_NIX_UPDATE ${pkgs.lib.getExe pkgs.nix-update}"
    "--set PACKAGE_UPDATES_SKOPEO ${pkgs.lib.getExe pkgs.skopeo}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/package_updates
  '';

  pythonImportsCheck = [ "package_updates" ];

  meta = {
    description = "Typed package and OCI update automation";
    license = pkgs.lib.licenses.mit;
    maintainers = with pkgs.lib.maintainers; [ booxter ];
    mainProgram = "update-packages";
    platforms = pkgs.lib.platforms.unix;
  };
}
