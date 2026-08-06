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
    test -z "$(gofmt -l cmd internal)"
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
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "qosctl";
    platforms = lib.platforms.linux;
  };
}
