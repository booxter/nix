{ lib }:
raw:
let
  pinNames = builtins.attrNames raw;
  pins = builtins.attrValues raw;
  expectedFields = [
    "changelog"
    "digest"
    "hash"
    "image"
    "ref"
    "tag"
    "tagRegex"
  ];
  assertionsFor =
    name:
    let
      pin = raw.${name};
      stringFields = [
        "changelog"
        "digest"
        "hash"
        "image"
        "ref"
        "tag"
        "tagRegex"
      ];
    in
    [
      {
        assertion = builtins.attrNames pin == expectedFields;
        message = "OCI image ${name} must contain exactly the supported pin fields";
      }
      {
        assertion = lib.all (field: builtins.isString pin.${field} && pin.${field} != "") stringFields;
        message = "OCI image ${name} pin fields must be non-empty strings";
      }
      {
        assertion = builtins.match "^sha256:[0-9a-f]{64}$" pin.digest != null;
        message = "OCI image ${name} must use a sha256 image digest";
      }
      {
        assertion = lib.hasPrefix "sha256-" pin.hash;
        message = "OCI image ${name} must use a sha256 Nix store hash";
      }
      {
        assertion = builtins.match pin.tagRegex pin.tag != null;
        message = "OCI image ${name} tag '${pin.tag}' does not match its update policy";
      }
      {
        assertion = pin.ref == "${pin.image}:${pin.tag}";
        message = "OCI image ${name} ref must be derived from its image and tag";
      }
    ];
in
[
  {
    assertion = pinNames != [ ];
    message = "OCI image facts must not be empty";
  }
  {
    assertion =
      builtins.length (map (pin: pin.ref) pins) == builtins.length (lib.unique (map (pin: pin.ref) pins));
    message = "OCI image refs must be unique";
  }
]
++ builtins.concatMap assertionsFor pinNames
