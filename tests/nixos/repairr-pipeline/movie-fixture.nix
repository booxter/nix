{ pkgs, video }:
{
  preStart = ''
    mkdir -p ${dirOf video}
    ${pkgs.ffmpeg-headless}/bin/ffmpeg -v error -y -f lavfi -i color=size=64x64:rate=1 -frames:v 1 -c:v mpeg4 ${video}
  '';
  serviceConfig = {
    RuntimeDirectory = "radarr-fixture";
    ExecStart = "${pkgs.python3}/bin/python3 ${./server.py} ${video}";
  };
}
