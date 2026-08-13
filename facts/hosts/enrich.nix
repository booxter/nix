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
  darwin = lib.mapAttrs (_: normalizeHostSpec false) raw.darwin;
  nixosSpecs = map normalizeNixosHostSpec raw.nixos;
  nixosNames = map (spec: spec.name) nixosSpecs;
  nixos =
    assert lib.assertMsg (
      builtins.length nixosNames == builtins.length (lib.unique nixosNames)
    ) "NixOS host names must be unique";
    builtins.listToAttrs (
      map (spec: {
        name = spec.name;
        value = spec;
      }) nixosSpecs
    );
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
