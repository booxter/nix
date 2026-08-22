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
    description = "Initialize and reconcile the local Smallstep CA";
    license = lib.licenses.mit;
    mainProgram = "step-ca-bootstrap";
    platforms = lib.platforms.linux;
  };
}
