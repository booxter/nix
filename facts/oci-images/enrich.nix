{ lib }:
raw:
lib.mapAttrs (
  name: pin:
  assert lib.assertMsg (!(pin ? ref)) "OCI image ${name} must not declare derived field ref";
  pin // { ref = "${pin.image}:${pin.tag}"; }
) raw
