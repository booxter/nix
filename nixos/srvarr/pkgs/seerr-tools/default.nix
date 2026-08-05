{
  buildGoModule,
  lib,
  makeWrapper,
  openssh,
}:
let
  application = buildGoModule {
    pname = "seerr-tools";
    version = "0.1.0";

    src = ./.;

    vendorHash = "sha256-KnBhJnsf8YAonb48o4rL4KUeF2LKtSwMNZc++CDd2cw=";

    subPackages = [
      "cmd/seerr-request-storage"
      "cmd/seerr-update-user-tags"
    ];

    nativeBuildInputs = [ makeWrapper ];

    postInstall = ''
      wrapProgram $out/bin/seerr-request-storage \
        --prefix PATH : ${lib.makeBinPath [ openssh ]}
      wrapProgram $out/bin/seerr-update-user-tags \
        --prefix PATH : ${lib.makeBinPath [ openssh ]}
    '';

    preCheck = ''
      test -z "$(gofmt -l .)"
      go vet ./...
    '';
    checkPhase = ''
      runHook preCheck
      go test ./... -cover
      runHook postCheck
    '';

    __darwinAllowLocalNetworking = true;

    meta = {
      description = "Seerr storage reporting and maintenance tools";
      license = lib.licenses.mit;
      maintainers = with lib.maintainers; [ booxter ];
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  };
  withMainProgram =
    mainProgram:
    application
    // {
      meta = application.meta // {
        inherit mainProgram;
      };
    };
in
{
  package = application;
  requestStorage = withMainProgram "seerr-request-storage";
  updateUserTags = withMainProgram "seerr-update-user-tags";
}
