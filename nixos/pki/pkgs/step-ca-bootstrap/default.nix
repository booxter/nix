{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "step-ca-bootstrap";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  subPackages = [ "cmd/step-ca-bootstrap" ];

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
    description = "Initialize and reconcile the local Smallstep CA";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "step-ca-bootstrap";
    platforms = lib.platforms.linux;
  };
}
