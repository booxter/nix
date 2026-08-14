{ lib, ... }:
let
  certificateType = lib.types.submodule {
    options = {
      category = lib.mkOption {
        type = lib.types.enum [
          "internal_https_server"
          "internal_https_client"
          "observability_endpoint_server"
          "observability_client"
        ];
        description = "Certificate issuance and rotation category.";
      };
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
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
  };
in
{
  options.host.pki.certificates = lib.mkOption {
    type = lib.types.attrsOf certificateType;
    default = { };
    internal = true;
    description = "Canonical certificate issuance and rotation registry for this host.";
  };
}
