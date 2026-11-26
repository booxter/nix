{ sopsPackage }:
sopsPackage.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ../../patches/sops-install-secrets-decrypt-with-remote-keyservice.patch
  ];

  # Upstream's full installer suite needs root; these decryption tests do not.
  doCheck = true;
  __darwinAllowLocalNetworking = true;
  checkPhase = ''
    runHook preCheck
    export TEST_ASSETS="$PWD/pkgs/sops-install-secrets/test-assets"
    go test ./pkgs/sops-install-secrets -run '^TestRemoteDecryption' -count=1
    runHook postCheck
  '';
})
