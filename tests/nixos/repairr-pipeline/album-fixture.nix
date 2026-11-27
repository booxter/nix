{
  pkgs,
  album,
  port,
}:
let
  ffmpeg = "${pkgs.ffmpeg-headless}/bin/ffmpeg";
in
{
  preStart = ''
    mkdir -p ${album}
    ${ffmpeg} -v error -y -f lavfi -i sine=frequency=440:duration=1 ${album}/01.flac
    ${ffmpeg} -v error -y -f lavfi -i sine=frequency=880:duration=1 ${album}/02.flac
  '';
  serviceConfig = {
    RuntimeDirectory = "lidarr-fixture";
    ExecStart = "${pkgs.python3}/bin/python3 ${./lidarr.py} ${album} ${toString port}";
  };
}
