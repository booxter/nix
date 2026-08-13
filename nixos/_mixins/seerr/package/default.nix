{
  buildGoModule,
  lib,
  seerr,
  seerr-api-go,
}:
buildGoModule {
  pname = "seerr-reconcile";
  inherit (seerr) version;

  src = ./.;
  vendorHash = "sha256-eWSPX7CPwiMkIHfnqWTfg8TJ6Jv5Z9aIGCJCuoa8Zxw=";

  postPatch = ''
    mkdir -p internal/seerrapi
    cp ${seerr-api-go}/share/gocode/seerrapi/*.go internal/seerrapi/
    chmod +w internal/seerrapi/*.go
    gofmt -w internal/seerrapi
  '';

  subPackages = [ "cmd/seerr-reconcile" ];

  preCheck = ''
    unformatted="$(gofmt -l cmd internal)"
    if [ -n "$unformatted" ]; then
      echo "Unformatted Go files:"
      echo "$unformatted"
      exit 1
    fi
    go vet ./...
  '';

  passthru = {
    inherit seerr seerr-api-go;
  };

  meta = {
    description = "Declarative Seerr settings reconciler";
    license = lib.licenses.mit;
    mainProgram = "seerr-reconcile";
    platforms = lib.platforms.linux;
  };
}
