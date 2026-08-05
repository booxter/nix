{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "wireguard-qos";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-ORb5fMHydpIjRnE1ZksW4IIMaNf3CDtoNkyOe8z4Fs0=";

  subPackages = [ "cmd/wireguard-qos" ];

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
    description = "Configure WireGuard traffic shaping through native netlink";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "wireguard-qos";
    platforms = lib.platforms.linux;
  };
}
