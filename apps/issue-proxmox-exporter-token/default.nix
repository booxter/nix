{
  age-plugin-se,
  hostInventory,
  lib,
  makeWrapper,
  nix,
  openssh,
  python3,
  ruff,
  sops,
  sopsTools,
}:
let
  pythonPackages = python3.pkgs;
  hostsFile = builtins.toFile "pki-tool-hosts.json" (
    builtins.toJSON (
      lib.mapAttrs (
        name: system:
        let
          spec = hostInventory.nixosHostSpecsByName.${name} or hostInventory.darwinHosts.${name};
        in
        {
          inherit system;
          secretDomain = hostInventory.secretDomainsByHost.${name};
          isWork = spec.isWork or false;
        }
      ) hostInventory.systemsByHost
    )
  );
  runtimePath = lib.makeBinPath [
    age-plugin-se
    nix
    openssh
    sops
  ];
in
pythonPackages.buildPythonApplication {
  pname = "issue-proxmox-exporter-token";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
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
    mypy src/proxmox_exporter_token
  '';

  pythonImportsCheck = [ "proxmox_exporter_token" ];

  postFixup = ''
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        --prefix PATH : ${runtimePath} \
        --set-default PKI_TOOLS_REPO_ROOT ${../..} \
        --set PKI_TOOLS_HOSTS_FILE ${hostsFile}
    done
  '';

  meta = {
    description = "Issue the Proxmox exporter API token and store it with SOPS";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "issue-proxmox-exporter-token";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
