{
  atomicFileWrites,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "oidc-synthetic-probe";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    atomicFileWrites
    httpx
    prometheus-client
    pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/oidc_synthetic_probe
  '';

  pythonImportsCheck = [ "oidc_synthetic_probe" ];

  meta = {
    description = "Synthetic OIDC and oauth2-proxy probe";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "oidc-synthetic-probe";
    platforms = lib.platforms.linux;
  };
}
