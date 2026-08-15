{ lib, ... }:
let
  categories = import ./categories.nix;
  certificateType = lib.types.submodule (
    { name, ... }:
    let
      keyParts = lib.splitString "/" name;
      validKey = builtins.length keyParts == 2 && lib.all (part: part != "") keyParts;
      category =
        if validKey then
          builtins.elemAt keyParts 0
        else
          throw "host.pki.certificates key '${name}' must be category/name";
      certificateName = builtins.elemAt keyParts 1;
    in
    {
      options = {
        category = lib.mkOption {
          type = lib.types.enum (builtins.attrNames categories);
          default = category;
          readOnly = true;
          internal = true;
          description = "Certificate issuance and rotation category.";
        };
        name = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = certificateName;
          readOnly = true;
          internal = true;
          description = "Certificate name within its host and category.";
        };
        secretPrefix = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "SOPS key prefix containing the certificate.";
        };
        commonName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Certificate common name.";
        };
        sans = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          apply = lib.unique;
          description = "Certificate subject alternative names.";
        };
        port = lib.mkOption {
          type = with lib.types; nullOr port;
          default = null;
          description = "Service port associated with this certificate, when applicable.";
        };
      };
    }
  );
in
{
  options.host.pki.certificates = lib.mkOption {
    type = lib.types.attrsOf certificateType;
    default = { };
    internal = true;
    description = "Canonical certificate issuance and rotation registry for this host.";
  };
}
