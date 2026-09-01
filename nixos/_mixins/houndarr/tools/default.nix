{
  houndarr,
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "houndarr-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    houndarr
  ]
  ++ (with pythonPackages; [
    httpx
    prometheus-client
    pydantic
  ]);

  nativeCheckInputs = with pythonPackages; [
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
