{
  glab,
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "attention-inbox";
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
    mypy src/attention_inbox
  '';

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ glab ])
  ];

  pythonImportsCheck = [ "attention_inbox" ];

  meta = {
    description = "Show external-service attention items in SketchyBar";
    license = lib.licenses.mit;
    mainProgram = "attention-inbox-sketchybar";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
