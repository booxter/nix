{ hostInventory, pkgs }:
let
  pythonPackages = pkgs.python3Packages;
  upsClientsByServer = import ../../lib/ups-clients.nix { lib = pkgs.lib; };
  upsClientsByServerFile = pkgs.writeText "ups-clients-by-server.json" (
    builtins.toJSON upsClientsByServer
  );
  secretDomainsByHostFile = pkgs.writeText "secret-domains-by-host.json" (
    builtins.toJSON hostInventory.secretDomainsByHost
  );
  systemsByHostFile = pkgs.writeText "systems-by-host.json" (
    builtins.toJSON hostInventory.systemsByHost
  );
  source = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = pkgs.lib.fileset.unions [
      ../../.sops.yaml
      ../../secrets
      ./pyproject.toml
      ./src
      ./tests
    ];
  };
  runtimePath = pkgs.lib.makeBinPath (
    with pkgs;
    [
      age
      age-plugin-se
      age-plugin-yubikey
      git
      mkpasswd
      nix
      openssh
      pass
      sops
    ]
  );
in
pythonPackages.buildPythonApplication {
  pname = "sops-tools";
  version = "0.1.0";
  pyproject = true;

  src = source;
  sourceRoot = "source/apps/sops";

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ pythonPackages.pyyaml ];

  nativeBuildInputs = [ pkgs.makeWrapper ];
  nativeCheckInputs = with pythonPackages; [
    pkgs.age
    pkgs.ruff
    pkgs.sops
    mypy
    pytestCheckHook
    pytest-cov
    types-pyyaml
  ];

  preCheck = ''
    ruff check src tests
    mypy src/sops_tools
  '';

  pythonImportsCheck = [ "sops_tools" ];

  postFixup = ''
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        --prefix PATH : ${runtimePath} \
        --set-default SOPS_TOOLS_REPO_ROOT ${../..} \
        --set SOPS_SECRET_DOMAINS_FILE ${secretDomainsByHostFile} \
        --set SOPS_HOST_SYSTEMS_FILE ${systemsByHostFile} \
        --set UPS_CLIENTS_BY_SERVER_FILE ${upsClientsByServerFile}
    done
  '';

  meta = {
    description = "Repository-aware helpers for managing host secrets with SOPS";
    license = pkgs.lib.licenses.mit;
    maintainers = with pkgs.lib.maintainers; [ booxter ];
    platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
  };
}
