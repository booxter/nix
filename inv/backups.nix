{
  readPublicKey,
}:
{
  server = {
    host = "beast";
    storage = {
      volume = "data";
      mount = "data";
      relativePath = "backups/restic-prod/hosts";
    };
  };

  offsite = {
    provider = "b2";
    bucketName = "ihar-restic-prod";
    repositoryPrefix = "hosts";
    rateMbit = 10;
    # Keep uploads serialized and packs small so shaped B2 requests finish
    # without timing out mid-pack.
    b2Connections = 1;
    packSizeMib = 4;
  };

  clients = {
    beast.publicKey = null;
    srvarr.publicKey = readPublicKey ../public-keys/restic/srvarr.pub;
    org = {
      publicKey = readPublicKey ../public-keys/restic/org.pub;
      # Repository names are durable storage identities. Keep the pre-rename
      # namespace so existing local and B2 snapshot history remains intact.
      storageName = "orgvm";
    };
    home.publicKey = readPublicKey ../public-keys/restic/home.pub;
    pki.publicKey = readPublicKey ../public-keys/restic/pki.pub;
  };
}
