{ config, lib, ... }:
let
  gpu = config.host.hardware.gpu;
  qsvAvailable = gpu.vendor == "intel" && gpu.renderDevice != null;
in
{
  # Compose Cyrillic combining sequences before BGN's Cyrillic-only filter.
  systemd.services.jellyfin.environment.JELLYFIN_TRANSLITERATOR_ID =
    "NFC; Russian-Latin/BGN; Any-Latin; Latin-Ascii; Lower; NFD; [:Nonspacing Mark:] Remove; [:Punctuation:] Remove;";

  host.jellyfinDeclarativeConfig = {
    system = {
      serverName = "main";
      libraryScanFanoutConcurrency = 4;
      parallelImageEncodingLimit = 2;
      enableMetrics = true;
      trickplayOptions = {
        enableHwAcceleration = qsvAvailable;
        enableHwEncoding = qsvAvailable;
        processThreads = 4;
      };
    };
    network.knownProxies = [ "127.0.0.1" ];
    metadata.useFileCreationTimeForDateAdded = false;
    encoding = {
      # TODO: revisit subtitle hardcoding policy once jellarr exposes
      # explicit subtitle-mode/burn-in options declaratively.
      enableHardwareEncoding = qsvAvailable;
      hardwareDecodingCodecs = [
        "h264"
        "hevc"
        "vp9"
        "av1"
      ];
      enableDecodingColorDepth10Hevc = true;
      enableDecodingColorDepth10Vp9 = true;
      allowHevcEncoding = true;
      allowAv1Encoding = false;
    }
    // lib.optionalAttrs qsvAvailable {
      hardwareAccelerationType = "qsv";
      qsvDevice = gpu.renderDevice;
    };
  };
}
