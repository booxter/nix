{
  python3,
  python3Packages,
  writeShellApplication,
}:
writeShellApplication {
  name = "box";
  text = ''
    exec ${python3}/bin/python3 ${./box.py} "$@"
  '';

  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [ python3Packages.pytest ];
  };
  checkPhase = ''
    runHook preCheck
    test_dir="$(mktemp -d)"
    cp ${./test_box.py} "$test_dir/test_box.py"
    cd "$test_dir"
    BOX_BIN=${./box.py} pytest -q test_box.py
    runHook postCheck
  '';
}
