{ pkgs, ... }: let
  awscliv2 = pkgs.python3Packages.buildPythonPackage rec {
    pname = "awscliv2";
    version = "2.3.1";
    pyproject = true;

    src = pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-X7vxBLzXeWt68QS9avmfbhUyCIgzma7/gw2Xs+o0964=";
    };

    build-system = [
      pkgs.python3Packages.poetry-core
    ];

    dependencies = with pkgs.python3Packages; [
      pip
    ];
  };
in with pkgs; python3Packages.buildPythonApplication rec {
  pname = "aws-automation";
  version = "1.2.1-unstable-2024-10-01";

  src = builtins.fetchGit {
    url = "ssh://git@gitlab.cee.redhat.com/compute/${pname}.git";
    rev = "b2878ee1f1610759b9741ac5c24cb5a271319ea9";
  };

  build-system = with python3Packages; [
    setuptools-scm
  ];
  dependencies = with python3Packages; [
    awscliv2
    # boto
    boto3
    botocore
    # not good...
    (kerberos.overrideAttrs (oldAttrs: {
      meta.knownVulnerabilities = [];
    }))
    python-ldap
    requests
  ];
}
