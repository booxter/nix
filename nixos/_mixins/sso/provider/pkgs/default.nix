pkgs:
let
  kanidmTools = pkgs.callPackage ./kanidm-tools { };
in
{
  kanidm-person-mail-provision = pkgs.callPackage ./kanidm-person-mail-provision {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  kanidm-mail-sender-bootstrap = kanidmTools;

  reset-oidc = kanidmTools;
}
