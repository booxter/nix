{ pkgs, ... }: with pkgs; python3Packages.buildPythonApplication rec {
  pname = "devnest";
  version = "0.0.3";

  src = ({ pname, version }: fetchgit {
    url = "https://github.com/rhos-infra/${pname}";
    branchName = "${version}";
    sha256 = "sha256-Ifo5cqR1Yh7sOLE+aVkRCl9+ymkisp8aKmGd7XrDF9k=";
  }) { inherit pname version; };

  env.PBR_VERSION = version;
  build-system = with python3Packages; [
    pbr
    pip
    setuptools
  ];
  dependencies = with python3Packages; [
    colorlog
    jenkinsapi
    terminaltables
    urllib3
    requests
    distro
  ];
}
