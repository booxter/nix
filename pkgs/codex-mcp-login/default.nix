{
  codex,
  lib,
  python3,
  pythonRuffCheckHook,
  serverNames ? [ ],
}:
let
  pythonPackages = python3.pkgs;
  serverFlags = lib.escapeShellArgs (
    lib.concatMap (name: [
      "--server"
      name
    ]) serverNames
  );
in
pythonPackages.buildPythonApplication {
  pname = "codex-mcp-login";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ codex ]}"
  ]
  ++ lib.optional (serverNames != [ ]) "--add-flags ${lib.escapeShellArg serverFlags}";

  preCheck = ''
    mypy src/codex_mcp_login
  '';

  pythonImportsCheck = [ "codex_mcp_login" ];

  meta = {
    description = "Repair expired Codex MCP OAuth credentials";
    license = lib.licenses.mit;
    mainProgram = "codex-mcp-login";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
