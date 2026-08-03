{
  lib,
  python3,
  ruff,
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
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/paperless_gpt_configure
  '';

  pythonImportsCheck = [ "paperless_gpt_configure" ];

  meta = {
    description = "Configure Paperless workflows used by paperless-gpt";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "paperless-gpt-configure";
    platforms = lib.platforms.linux;
  };
}
