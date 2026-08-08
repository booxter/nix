{ ... }:
{
  services.lolek = {
    maxConcurrentDownloads = 4;
    maxConcurrentDownloadsPerChat = 2;
    postSourceCaption = true;
    postRequesterCaption = true;
    galleryDownloadEnabled = true;
    maxGalleryMedia = 20;
    hardwareAcceleration.useHost = true;
    metrics.enable = true;
    localTelegramBotApi = {
      enable = true;
      verbosity = 1;
    };
  };
}
