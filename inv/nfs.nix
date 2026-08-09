{
  providers.beast = {
    backingMount = "/volume2";
    exports = {
      media = {
        path = "/volume2/Media";
        fsid = 10;
        permissions.sharedGroup = {
          name = "media";
          gid = 169;
        };
      };
      nixCache = {
        path = "/volume2/nix-cache";
        fsid = 11;
      };
      paperless = {
        path = "/volume2/paperless";
        fsid = 12;
        anonymousIdentity = "paperless";
      };
    };
  };

  links = {
    srvarr.media = {
      provider = "beast";
      export = "media";
      mountPoint = "/data/media";
    };
    cache.nixCache = {
      provider = "beast";
      export = "nixCache";
      mountPoint = "/cache";
    };
    org.paperless = {
      provider = "beast";
      export = "paperless";
      mountPoint = "/data/paperless";
    };
  };
}
