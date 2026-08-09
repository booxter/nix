{
  buildGoModule,
  lib,
}:
buildGoModule {
  pname = "grafana-dashboards";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-4Qbf+6Zn2yq/yyvyZldKtiWhDyYw0fsaRYRAJDzdmbI=";

  subPackages = [ "cmd/grafana-dashboards" ];

  preCheck = ''
    test -z "$(gofmt -l .)"
    go vet ./...
  '';
  checkPhase = ''
    runHook preCheck
    go test ./... -cover
    runHook postCheck
  '';

  meta = {
    description = "Generate inventory-driven Grafana dashboards";
    license = lib.licenses.mit;
    mainProgram = "grafana-dashboards";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
