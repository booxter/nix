{ lib, ... }:
let
  serverModule = {
    options = {
      repositoryRoot = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Directory containing one Restic repository per client.";
      };

      offsite = lib.mkOption {
        type =
          with lib.types;
          nullOr (submodule {
            options = {
              backend = lib.mkOption {
                type = enum [
                  "b2"
                  "s3"
                ];
                default = "s3";
                description = "Restic backend used for offsite repositories.";
              };
              endpoint = lib.mkOption {
                type = nullOr nonEmptyStr;
                default = null;
                description = "S3-compatible API endpoint.";
              };
              bucket = lib.mkOption {
                type = nonEmptyStr;
                description = "Object-storage bucket containing the repositories.";
              };
              prefix = lib.mkOption {
                type = str;
                default = "";
                description = "Object prefix containing one repository per client.";
              };
              storageProvider = lib.mkOption {
                type = nullOr (enum [ "b2" ]);
                default = null;
                description = "Provider used for provider-specific usage metrics.";
              };
              qos = lib.mkOption {
                type = bool;
                default = false;
                description = "Whether to shape offsite backup uploads.";
              };
            };
          });
        default = null;
        description = "Server-managed offsite replication configuration.";
      };
    };
  };
in
{
  options.host.backups.server = lib.mkOption {
    type = with lib.types; nullOr (submodule serverModule);
    default = null;
    description = "Restic SFTP repository and cloud-offload server configuration.";
  };
}
