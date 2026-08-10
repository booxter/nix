{ config, ... }:
{
  host.jellyfin.declarativeConfig = {
    system = {
      serverName = "main";
      libraryScanFanoutConcurrency = 4;
      parallelImageEncodingLimit = 2;
      enableMetrics = true;
      trickplayOptions = {
        enableHwAcceleration = true;
        enableHwEncoding = true;
        processThreads = 4;
      };
    };
    network.knownProxies = [ "127.0.0.1" ];
    encoding = {
      # TODO: revisit subtitle hardcoding policy once jellarr exposes
      # explicit subtitle-mode/burn-in options declaratively.
      enableHardwareEncoding = true;
      hardwareAccelerationType = "qsv";
      qsvDevice = config.host.hardware.gpu.renderDevice;
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
    };
  };
}
