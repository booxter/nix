{
  houndarr,
  lib,
  python313Packages,
  pythonRuffCheckHook,
}:
# The helpers import Houndarr's modules from its Python 3.13 installation.
python313Packages.buildPythonApplication {
  pname = "houndarr-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python313Packages.setuptools ];
  dependencies = [
    houndarr
  ]
  ++ (with python313Packages; [
    httpx
    prometheus-client
    pydantic
  ]);

  nativeCheckInputs = with python313Packages; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/houndarr_tools
  '';

  pythonImportsCheck = [ "houndarr_tools" ];

  meta = {
    description = "Reconciliation and status helpers for Houndarr";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
