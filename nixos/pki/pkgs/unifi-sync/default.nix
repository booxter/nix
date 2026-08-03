{
  lib,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "unifi-sync";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/unifi_sync
  '';

  pythonImportsCheck = [ "unifi_sync" ];

  meta = {
    description = "Sync UniFi reservations, DHCP settings, DNS records, and static routes from inventory";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "unifi-sync";
    platforms = lib.platforms.linux;
  };
}
