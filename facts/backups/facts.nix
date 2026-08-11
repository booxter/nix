{ facts }:
let
  publicKeys = facts.public-keys;
in
{
  providers.beast = {
    repositoryRoot = "/volume2/backups/restic-prod/hosts";

    offsite.b2 = {
      backend = "b2";
      bucketName = "ihar-restic-prod";
      prefix = "hosts";
    };
  };

  links = {
    beast.primary = {
      provider = "beast";
      transport = "local";
      offsite = "b2";
    };

    srvarr.primary = {
      provider = "beast";
      publicKey = publicKeys.restic.srvarr;
      offsite = "b2";
    };

    org.primary = {
      provider = "beast";
      publicKey = publicKeys.restic.org;
      # Repository names are durable storage identities. Keep the pre-rename
      # namespace so existing local and B2 snapshot history remains intact.
      storageName = "orgvm";
      offsite = "b2";
    };

    home.primary = {
      provider = "beast";
      publicKey = publicKeys.restic.home;
      offsite = "b2";
    };

    pki.primary = {
      provider = "beast";
      publicKey = publicKeys.restic.pki;
      offsite = "b2";
    };
  };
}
