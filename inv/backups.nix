{ readPublicKey }:
{
  server = {
    host = "beast";
    repositoryRoot = "/volume2/backups/restic-prod/hosts";
    localClient = "beast";
  };

  cloud.bucketName = "ihar-restic-prod";

  clients = {
    beast.publicKey = null;
    srvarr.publicKey = readPublicKey ../../public-keys/restic/srvarr.pub;
    org = {
      publicKey = readPublicKey ../../public-keys/restic/org.pub;
      # Repository names are durable storage identities. Keep the pre-rename
      # namespace so existing local and B2 snapshot history remains intact.
      storageName = "orgvm";
    };
    home.publicKey = readPublicKey ../../public-keys/restic/home.pub;
    pki.publicKey = readPublicKey ../../public-keys/restic/pki.pub;
  };
}
