{
  age-plugin-se,
  atomicFileWrites,
  lib,
  makeWrapper,
  nix,
  openssh,
  python3,
  pythonRuffCheckHook,
  sops,
  sopsTools,
  step-cli,
}:
let
  pythonPackages = python3.pkgs;
  inventoryQuerySource = builtins.path {
    path = ../..;
    name = "pki-inventory-query-source";
  };
  inventoryQueryFile = "${inventoryQuerySource}/apps/pki-certificates/inventory-query.nix";
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
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/pki_certificates
  '';

  pythonImportsCheck = [ "pki_certificates" ];

  passthru = {
    inherit inventoryQueryFile;
  };

  postFixup = ''
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        --prefix PATH : ${runtimePath} \
        --set PKI_CERTIFICATE_INVENTORY_QUERY_FILE ${inventoryQueryFile}
    done
  '';

  meta = {
    description = "Issue and store fleet PKI certificates";
    license = lib.licenses.mit;
    mainProgram = "issue-internal-service-cert";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
