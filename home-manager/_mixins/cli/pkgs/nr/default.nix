{
  builders ? "",
  lib,
  nixpkgs-reviewFull,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "nr";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ nixpkgs-reviewFull ]}"
    "--set NR_BUILDERS ${lib.escapeShellArg builders}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/nr
  '';

  pythonImportsCheck = [ "nr" ];

  meta = {
    description = "Review a nixpkgs pull request using the fleet's remote builders";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "nr";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
