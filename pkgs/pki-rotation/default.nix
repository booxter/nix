{
  atomicFileWrites,
  git,
  gitCommandRunner,
  lib,
  makeWrapper,
  nix,
  pkiCertificates,
  python3,
  ruff,
  sops,
  sopsTools,
  stdenv,
  sudo,
}:
let
  pythonPackages = python3.pkgs;
  runtimePath = lib.makeBinPath (
    [
      git
      nix
      sops
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ sudo ]
  );
in
pythonPackages.buildPythonApplication {
  pname = "pki-rotation";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.cryptography
    gitCommandRunner
    pkiCertificates
    pythonPackages.prometheus-client
    pythonPackages.pydantic
    pythonPackages.pygithub
    sopsTools
  ];

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/pki_rotation
  '';

  pythonImportsCheck = [ "pki_rotation" ];

  postFixup = ''
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        --prefix PATH : ${runtimePath} \
        --set PKI_ROTATION_HOSTS_FILE ${pkiCertificates.hostsFile} \
        --set PKI_ROTATION_QUERY_FILE ${pkiCertificates.queryFile} \
        --set PKI_ROTATION_CERTIFICATE_HELPER ${pkiCertificates}/bin/pki-issue-certificate-remote \
        --set PKI_ROTATION_GIT_ASKPASS "$out/bin/pki-rotation-git-askpass"
    done
  '';

  meta = {
    description = "Inspect and rotate repository-managed internal PKI certificates";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "pki-rotation";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
