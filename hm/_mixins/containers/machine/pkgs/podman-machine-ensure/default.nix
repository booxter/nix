{
  buildGoModule,
  lib,
  makeWrapper,
  podman,
}:
buildGoModule {
  pname = "podman-machine-ensure";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;

  nativeBuildInputs = [ makeWrapper ];

  postFixup = ''
    wrapProgram "$out/bin/podman-machine-ensure" \
      --prefix PATH : ${lib.makeBinPath [ podman ]}
  '';

  preCheck = ''
    unformatted="$(gofmt -l .)"
    if test -n "$unformatted"; then
      gofmt -d . >&2
      exit 1
    fi
    go vet ./...
  '';
  checkFlags = [ "-cover" ];

  meta = {
    description = "Reconcile a declaratively configured Podman machine";
    license = lib.licenses.mit;
    mainProgram = "podman-machine-ensure";
    platforms = lib.platforms.darwin;
  };
}
