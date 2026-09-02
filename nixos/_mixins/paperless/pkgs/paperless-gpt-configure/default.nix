{
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "paperless-gpt-configure";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = with pythonPackages; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/paperless_gpt_configure
  '';

  pythonImportsCheck = [ "paperless_gpt_configure" ];

  meta = {
    description = "Configure Paperless workflows used by paperless-gpt";
    license = lib.licenses.mit;
    mainProgram = "paperless-gpt-configure";
    platforms = lib.platforms.linux;
  };
}
