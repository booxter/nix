{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "open-webui-tool-acl-reconcile";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    httpx
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
    mypy src/open_webui_tool_acl_reconcile
  '';

  pythonImportsCheck = [ "open_webui_tool_acl_reconcile" ];

  meta = {
    description = "Reconcile an Open WebUI tool server ACL with a group";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "open-webui-tool-acl-reconcile";
    platforms = lib.platforms.linux;
  };
}
