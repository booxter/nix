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
  pname = "kanidm-person-mail-provision";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ atomicFileWrites ];

  nativeCheckInputs = [
    ruff
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/kanidm_person_mail_provision
  '';

  pythonImportsCheck = [ "kanidm_person_mail_provision" ];

  meta = {
    description = "Render person mail addresses as Kanidm provisioning JSON";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "kanidm-person-mail-provision";
    platforms = lib.platforms.linux;
  };
}
