{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "qosctl";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-A46Q/+WjUMF78c/84wLmydP8hbqMPcdDqljHRmcoNOw=";

  subPackages = [ "cmd/qosctl" ];

  preCheck = ''
    unformatted="$(gofmt -l cmd internal)"
    if test -n "$unformatted"; then
      gofmt -d cmd internal >&2
      exit 1
    fi
    go vet ./...
  '';
  checkPhase = ''
    runHook preCheck
    go test ./... -cover
    runHook postCheck
  '';

  meta = {
    description = "Apply named per-interface traffic limits";
    license = lib.licenses.mit;
    mainProgram = "qosctl";
    platforms = lib.platforms.linux;
  };
}
