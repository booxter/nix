{
  lib,
  nodejs,
  oapi-codegen,
  runCommand,
  seerr,
  typescript,
}:
runCommand "seerr-api-go-${seerr.version}"
  {
    nativeBuildInputs = [
      oapi-codegen
      nodejs
    ];

    passthru = {
      inherit seerr;
      inherit (seerr) version;
      apiSpec = "${seerr.src}/seerr-api.yml";
    };

    meta = {
      description = "Go bindings generated from Seerr's OpenAPI specification";
      homepage = "https://github.com/seerr-team/seerr";
      license = lib.licenses.mit;
    };
  }
  ''
    cp ${./config.yaml} config.yaml
    cp ${./seerr-api.overlay.yaml} seerr-api.overlay.yaml
    oapi-codegen --config config.yaml ${seerr.src}/seerr-api.yml
    # HACK: Seerr uses named bitmask enums in TypeScript but omits them from
    # its OpenAPI contract. Parse the AST rather than copying numeric values.
    # TODO(seerr): ask upstream to expose these enums in seerr-api.yml or
    # another versioned machine-readable artifact, then remove this extractor.
    TYPESCRIPT_LIB=${typescript}/lib/node_modules/typescript/lib/typescript.js \
      node ${./generate-constants.js} \
      --permissions ${seerr.src}/server/lib/permissions.ts \
      --notifications ${seerr.src}/server/lib/notifications/index.ts \
      > constants.gen.go

    test -s client.gen.go
    grep -q 'GetSettingsJellyfin' client.gen.go
    grep -q 'GetSettingsRadarr' client.gen.go
    grep -q 'GetSettingsSonarr' client.gen.go
    grep -q 'GetSettingsNotificationsTelegram' client.gen.go
    grep -q 'MediaServerLogin' client.gen.go
    grep -q 'MonitorNewItems' client.gen.go
    grep -q 'PermissionRequest = 32' constants.gen.go
    grep -q 'NotificationMediaPending = 2' constants.gen.go

    install -Dm644 client.gen.go $out/share/gocode/seerrapi/client.gen.go
    install -Dm644 constants.gen.go $out/share/gocode/seerrapi/constants.gen.go
  ''
