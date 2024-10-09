# Work in Progress, only basic commands like `clone` work
{ pkgs, ... }: let
  koji = with pkgs; python3Packages.buildPythonPackage rec {
    pname = "koji";
    version = "1.35.0";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-chN6hB1w3dyHIJGvV2C1I21K65VuiMXTPYBGfK39xHU=";
    };

    dependencies = with python3Packages; [
      cheetah3
      psycopg2
      python-dateutil
      defusedxml
    ];
  };
  rpkg = with pkgs; python3Packages.buildPythonPackage rec {
    pname = "rpkg";
    version = "1.67";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-qcXhVCrLshDKhSn/dPmoKhzQ38u1l6Bgy0M0D2hxgwU=";
    };

    build-system = with python3Packages; [
      pip
      setuptools
    ];

    dependencies = with python3Packages; [
      argcomplete
      cccolutils
      gitpython
      koji
      pycurl
      pyyaml
      requests
      python3Packages.rpm
      six
    ];

    postPatch = ''
      substituteInPlace setup.py \
        --replace-fail ", 'pytest-runner'" ""
      substituteInPlace pyproject.toml \
        --replace-fail '"GPL-2.0-or-later"' '{ file = "GPL-2.0-or-later" }'
    '';
  };
  kobo = with pkgs; python3Packages.buildPythonPackage rec {
    pname = "kobo";
    version = "0.37.0";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-Be6Vb7QK/z6qKr8s3skxJF9db7a6jqbBn24mx+pgL7k=";
    };

    build-system = with python3Packages; [
      pip
      setuptools
    ];

    dependencies = with python3Packages; [
      six
    ];
  };
  brewkoji = with pkgs; stdenv.mkDerivation rec {
    pname = "brewkoji";
    version = "1.33";

    src = builtins.fetchGit {
      url = "ssh://git@gitlab.cee.redhat.com/brew/${pname}.git";
      rev = "2d71ae4d97364fb1477168e952ccdd96533fba81";
    };

    nativeBuildInputs = [ pkgs.python3 ];

    installPhase = ''
      make install DESTDIR=$out PYTHON=python3
    '';
  };
in with pkgs; python3Packages.buildPythonApplication rec {
  pname = "rhpkg";
  version = "1.46";

  src = builtins.fetchGit {
    url = "ssh://git@gitlab.cee.redhat.com/devops-compose/${pname}.git";
    rev = "8f0f43ac95e860a91b51af53ff638796892af162";
  };

  nativeBuildInputs = [ pkgs.installShellFiles pkgs.makeWrapper ];

  dependencies = with python3Packages; [
    git
    gitpython
    brewkoji
    koji
    kobo
    rpkg
    bugzilla
    # python2-rhmsg
    # python-saslwrapper
    # rpmdiff-remote
  ];

  postBuild = ''
    python3 ./doc/rhpkg_man_page.py > rhpkg.1
    cp rhpkg.1 rhpkg-stage.1

    for dst in rhpkg-stage rhpkg-sha512 rhpkg-stage-sha512; do
      cp ./etc/bash_completion.d/rhpkg.bash ./etc/bash_completion.d/$dst.bash
      ${pkgs.gnused}/bin/sed -i -- "s/complete -F _rhpkg rhpkg/complete -F _rhpkg $dst/g" ./etc/bash_completion.d/$dst.bash
    done
  '';

  postInstall = ''
    installManPage *.1
    for cmd in rhpkg rhpkg-stage rhpkg-sha512 rhpkg-stage-sha512; do
      cp ./etc/bash_completion.d/rhpkg.bash ./etc/bash_completion.d/$dst.bash
      installShellCompletion ./etc/bash_completion.d/$dst.bash
    done
    mkdir $out/etc; cp -r ./etc/rpkg $out/etc
  '';

  postFixup = ''
    for cmd in rhpkg rhpkg-stage; do
      wrapProgram $out/bin/$cmd --add-flags "-C $out/etc/rpkg/$cmd.conf" --set NIX_SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
    done
  '';
}
