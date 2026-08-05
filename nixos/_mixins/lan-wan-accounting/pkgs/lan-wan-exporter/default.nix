{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "lan-wan-exporter";
  version = "0.1.0";

  src = ./.;
  vendorHash = "sha256-mNZGXtrVbLJyx2KxzfUB8WATUp9k5hxqCKlRIhOzxBY=";

  subPackages = [ "cmd/lan-wan-export" ];

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
    description = "Export nftables LAN/WAN counters through native netlink";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "lan-wan-export";
    platforms = lib.platforms.linux;
  };
}
