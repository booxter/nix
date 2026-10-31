{
  curl,
  lib,
  openssh,
  python3,
  pythonRuffCheckHook,
  sshpass,
  stdenv,
  tart ? null,
}:
let
  pythonPackages = python3.pkgs;
  atomicFileWrites = pythonPackages.callPackage ../../pkgs/atomic-file-writes {
    inherit pythonRuffCheckHook;
  };
  image = builtins.toFile "macos-vm-image.json" (builtins.toJSON (import ./image.nix));
in
pythonPackages.buildPythonApplication {
  pname = "fleet-macos-vm";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    openssh
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];
  preCheck = ''
    mypy src/fleet_macos_vm
  '';

  makeWrapperArgs = [
    "--set FLEET_VM_IMAGE ${image}"
    "--prefix PATH : ${
      lib.makeBinPath (
        [
          curl
          openssh
          sshpass
        ]
        ++ lib.optional stdenv.hostPlatform.isDarwin tart
      )
    }"
  ];

  pythonImportsCheck = [ "fleet_macos_vm" ];
  meta = {
    description = "Prepare and run local macOS development VMs";
    license = lib.licenses.mit;
    mainProgram = "fleet-macos-vm";
    platforms = lib.platforms.unix;
  };
}
