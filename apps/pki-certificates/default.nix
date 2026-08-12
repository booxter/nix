{
  age-plugin-se,
  atomicFileWrites,
  lib,
  makeWrapper,
  nix,
  openssh,
  python3,
  ruff,
  sops,
  sopsTools,
  step-cli,
}:
let
  pythonPackages = python3.pkgs;
  runtimePath = lib.makeBinPath [
    age-plugin-se
    nix
    openssh
    sops
    step-cli
  ];
in
pythonPackages.buildPythonApplication {
  pname = "pki-certificates";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.pydantic
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
    mypy src/pki_certificates
  '';

  pythonImportsCheck = [ "pki_certificates" ];

  passthru = {
    hostsQueryFile = ./hosts-query.nix;
    queryFile = ./query.nix;
  };

  postFixup = ''
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        --prefix PATH : ${runtimePath} \
        --set PKI_CERTIFICATE_HOSTS_QUERY_FILE ${./hosts-query.nix} \
        --set PKI_CERTIFICATE_QUERY_FILE ${./query.nix}
    done
  '';

  meta = {
    description = "Issue and store fleet PKI certificates";
    license = lib.licenses.mit;
    mainProgram = "issue-internal-service-cert";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
