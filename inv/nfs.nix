{
  providers.beast = {
    backingMount = "/volume2";
    exports = {
      media = {
        storage = "media";
        fsid = 10;
      };
      nixCache = {
        storage = "nixCache";
        fsid = 11;
      };
      paperless = {
        storage = "paperless";
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
