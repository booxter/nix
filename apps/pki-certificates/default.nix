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
  step-cli,
}:
let
  pythonPackages = python3.pkgs;
  hostsFile = builtins.toFile "pki-certificate-hosts.json" (
    builtins.toJSON (
      lib.mapAttrs (
        name: system:
        let
          nixosSpec = hostInventory.nixosHostSpecsByName.${name} or null;
          spec = if nixosSpec != null then nixosSpec else hostInventory.darwinHosts.${name};
          caServer = spec.caServer or null;
        in
        {
          inherit system;
          configuration = if nixosSpec != null then "nixosConfigurations" else "darwinConfigurations";
          runtimeHost = spec.hostname or name;
          secretDomain = hostInventory.secretDomainsByHost.${name};
          caUrl =
            if caServer == null then
              null
            else
              "https://${hostInventory.toNixosPrimaryDnsName spec}:${toString caServer.port}";
        }
      ) hostInventory.systemsByHost
    )
  );
  unifiDefaultsFile = builtins.toFile "pki-unifi-defaults.json" (
    builtins.toJSON {
      commonName = "unifi.${hostInventory.site.lan.domain}";
      sans = [
        "unifi.${hostInventory.site.lan.domain}"
        "unifi"
      ];
      gatewayIp = hostInventory.site.lan.gateway.address;
    }
  );
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
    inherit hostsFile unifiDefaultsFile;
    queryFile = ./query.nix;
  };

  postFixup = ''
    for program in "$out"/bin/*; do
      wrapProgram "$program" \
        --prefix PATH : ${runtimePath} \
        --set-default PKI_TOOLS_REPO_ROOT ${../..} \
        --set PKI_CERTIFICATE_HOSTS_FILE ${hostsFile} \
        --set PKI_CERTIFICATE_QUERY_FILE ${./query.nix} \
        --set PKI_UNIFI_DEFAULTS_FILE ${unifiDefaultsFile}
    done
  '';

  meta = {
    description = "Issue and store fleet PKI certificates";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "issue-internal-service-cert";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
