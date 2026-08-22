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
    description = "Export nftables LAN/WAN counters through native netlink";
    license = lib.licenses.mit;
    mainProgram = "lan-wan-export";
    platforms = lib.platforms.linux;
  };
}
