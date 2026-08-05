{
  codex,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "codex-mcp-init";
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
    "--prefix PATH : ${lib.makeBinPath [ codex ]}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/codex_mcp_init
  '';

  pythonImportsCheck = [ "codex_mcp_init" ];

  meta = {
    description = "Authenticate configured Codex HTTP MCP servers";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "codex-mcp-init";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
