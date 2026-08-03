{
  lib,
  openssh,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "ssh-ticket";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  nativeCheckInputs = [ python3.pkgs.pytestCheckHook ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ openssh ]}"
  ];

  pythonImportsCheck = [ "ssh_ticket" ];

  meta = {
    description = "Issue per-host short-lived SSH user certificates and connect through ssht";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ssh-ticket";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
