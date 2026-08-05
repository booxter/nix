{
  lib,
  postgresql,
  postgresqlTestHook,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "postgresql-role-password";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ pythonPackages.psycopg ];

  nativeCheckInputs =
    with pythonPackages;
    [
      mypy
      pytestCheckHook
      pytest-cov
      ruff
    ]
    ++ [
      postgresql
      postgresqlTestHook
    ];

  postgresqlTestUserOptions = "LOGIN SUPERUSER";

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/postgresql_role_password
  '';

  pythonImportsCheck = [ "postgresql_role_password" ];

  meta = {
    description = "Set PostgreSQL role passwords from secret files";
    license = lib.licenses.mit;
    mainProgram = "postgresql-set-role-password";
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux;
  };
}
