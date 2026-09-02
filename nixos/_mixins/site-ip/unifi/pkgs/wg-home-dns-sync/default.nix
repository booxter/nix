{
  lib,
  python3,
  pythonRuffCheckHook,
  unifiSync,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "wg-home-dns-sync";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    httpx
    prometheus-client
    pydantic
    unifiSync
  ];

  nativeCheckInputs = with pythonPackages; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/wg_home_dns_sync
  '';

  pythonImportsCheck = [ "wg_home_dns_sync" ];

  meta = {
    description = "Sync home WireGuard peer DNS overrides to UniFi";
    license = lib.licenses.mit;
    mainProgram = "wg-home-dns-sync";
    platforms = lib.platforms.linux;
  };
}
