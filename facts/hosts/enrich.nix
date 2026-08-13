{
  context,
  lib,
}:
raw:
let
  inherit (context) lanDomain;
  normalizeHostSpec =
    isLinux: spec:
    let
      validated =
        assert lib.assertMsg (
          spec ? realm && builtins.isString spec.realm && spec.realm != ""
        ) "host ${spec.name} must declare a non-empty realm";
        spec;
      lowercaseName = lib.toLower validated.name;
    in
    validated
    // {
      localDnsName = "${validated.name}.local";
      sshKnownHostNames = lib.unique (
        [ validated.name ]
        ++ lib.optional (lowercaseName != validated.name) lowercaseName
        ++ lib.optional isLinux "${validated.name}.${lanDomain}"
        ++ [ "${validated.name}.local" ]
        ++ lib.optional (lowercaseName != validated.name) "${lowercaseName}.local"
      );
    };
  normalizeNixosHostSpec =
    spec:
    let
      normalized = normalizeHostSpec true spec;
    in
    normalized
    // {
      certificateDnsNames = [
        normalized.name
        "${normalized.name}.${lanDomain}"
        normalized.localDnsName
      ];
    };
  darwin = lib.mapAttrs (name: spec: normalizeHostSpec false (spec // { inherit name; })) raw.darwin;
  nixos = lib.mapAttrs (name: spec: normalizeNixosHostSpec (spec // { inherit name; })) raw.nixos;
  hostSpecsByName = darwin // nixos;
  realmNames = lib.unique (map (spec: spec.realm) (builtins.attrValues hostSpecsByName));
in
raw
// {
  inherit
    darwin
    hostSpecsByName
    nixos
    realmNames
    ;
}
