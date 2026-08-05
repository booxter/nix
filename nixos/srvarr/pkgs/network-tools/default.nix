{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "srvarr-network-tools";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-n/S9knZuLgr4Lgv/+o5w1/Rd8E8Qfc5uymfBl7rfYJ0=";

  subPackages = [ "cmd/wg-bridge-access" ];

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
    description = "Native network namespace tools for srvarr";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "wg-bridge-access";
    platforms = lib.platforms.linux;
  };
}
