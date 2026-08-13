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
      lowercaseName = lib.toLower spec.name;
    in
    spec
    // {
      localDnsName = "${spec.name}.local";
      sshKnownHostNames = lib.unique (
        [ spec.name ]
        ++ lib.optional (lowercaseName != spec.name) lowercaseName
        ++ lib.optional isLinux "${spec.name}.${lanDomain}"
        ++ [ "${spec.name}.local" ]
        ++ lib.optional (lowercaseName != spec.name) "${lowercaseName}.local"
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
in
raw
// {
  inherit
    darwin
    hostSpecsByName
    nixos
    ;
}
