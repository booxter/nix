{ lib, pkgs }: with pkgs; let
  beaker-common = python3Packages.buildPythonPackage rec {
    pname = "beaker-common";
    version = "29.1";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-g/YqlJDF0373NvNW+u8Jc4/jqwRSvSq/snOzi6NT9bI=";
    };
  };
in python3Packages.buildPythonApplication rec {
  pname = "beaker-client";
  version = "29.1";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-8RTaK6u5VMaaDpZOln0yO0QN9r6cNO/FsZnSaPmKFvc=";
  };

  propagatedBuildInputs = with python3Packages; [
    jinja2
    prettytable
    beaker-common
    gssapi
    lxml
    requests
    setuptools  # required for finding pkg_resources at runtime
    six
  ];

  meta = {
    homepage = "https://beaker-project.org/";
    description = "Command-line client for interacting with Beaker";
    license = lib.licenses.gpl2Plus;
    maintainers = [ lib.maintainers.booxter ];
  };
}

