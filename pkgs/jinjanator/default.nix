{
  lib,
  python3,
  fetchPypi,
}:
let
  jinjanator-plugins = python3.pkgs.buildPythonPackage rec {
    pname = "jinjanator-plugins";
    version = "24.2.0";
    pyproject = true;

    src = fetchPypi {
      pname = "jinjanator_plugins";
      inherit version;
      hash = "sha256-X6juy22fvvXnlHs4INpL17LvPxAnIeQjgt5eceUrQJo=";
    };

    build-system = with python3.pkgs; [
      hatch-fancy-pypi-readme
      hatch-vcs
      hatchling
    ];

    dependencies = with python3.pkgs; [
      attrs
      pluggy
      typing-extensions
    ];

    pythonRelaxDeps = [
      "hatchling"
    ];

    pythonImportsCheck = [
      "jinjanator_plugins"
    ];

    meta = {
      description = "Package which provides the plugin API for the jinjanator tool";
      homepage = "https://pypi.org/project/jinjanator-plugins";
      license = lib.licenses.asl20;
      maintainers = with lib.maintainers; [ booxter ];
    };
  };
in
python3.pkgs.buildPythonApplication rec {
  pname = "jinjanator";
  version = "25.2.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-0984wmf5J0rVRgpPKbiLRg3kCpFV38myhjPDisQt92Y=";
  };

  build-system = [
    python3.pkgs.hatch-fancy-pypi-readme
    python3.pkgs.hatch-vcs
    python3.pkgs.hatchling
  ];

  dependencies = with python3.pkgs; [
    attrs
    hatchling
    jinja2
    jinjanator-plugins
    python-dotenv
    pyyaml
    typing-extensions
  ];

  postPatch = ''
    substituteInPlace pyproject.toml --replace-fail \
      "hatchling<1.27" "hatchling"
  '';

  pythonImportsCheck = [
    "jinjanator"
  ];

  meta = {
    description = "Command-line interface to Jinja2 for templating in shell scripts";
    homepage = "https://pypi.org/project/jinjanator/";
    license = with lib.licenses; [
      bsd2
      asl20
    ];
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "jinjanator";
  };
}
