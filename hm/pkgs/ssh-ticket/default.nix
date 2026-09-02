{
  atomicFileWrites,
  lib,
  openssh,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "ssh-ticket";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [
    atomicFileWrites
    pythonPackages.pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/ssh_ticket
  '';

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ openssh ]}"
  ];

  pythonImportsCheck = [ "ssh_ticket" ];

  meta = {
    description = "Issue per-host short-lived SSH user certificates and connect through ssht";
    license = lib.licenses.mit;
    mainProgram = "ssh-ticket";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
