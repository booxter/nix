{ pkgs, ... }: with pkgs; python3Packages.buildPythonApplication rec {
  pname = "devnest";
  version = "0.0.3";
  env.PBR_VERSION = version;

  # src = pkgs.fetchFromGitHub {
  #   owner = "rhos-infra";
  #   repo = "devnest";
  #   rev = "bc72a842cd5cab5eb3175de0a67962a16433473c";
  #   hash = "sha256-Ifo5cqR1Yh7sOLE+aVkRCl9+ymkisp8aKmGd7XrDF9k=";
  # };
  src = ({ pname, version }: fetchgit {
    url = "https://github.com/rhos-infra/${pname}";
    branchName = "${version}";
    sha256 = "sha256-Ifo5cqR1Yh7sOLE+aVkRCl9+ymkisp8aKmGd7XrDF9k=";
  }) { inherit pname; inherit version; };
  # buildInputs = [ python3Packages.pip ];
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
