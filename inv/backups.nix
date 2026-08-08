{
  readPublicKey,
  storage,
}:
{
  server = {
    host = "beast";
    repositoryRoot = "${storage.hosts.beast.volumes.data.mounts.data.mountPoint}/backups/restic-prod/hosts";
    localClient = "beast";
  };

  offsite = {
    provider = "b2";
    bucketName = "ihar-restic-prod";
    repositoryPrefix = "hosts";
    rateMbit = 10;
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
