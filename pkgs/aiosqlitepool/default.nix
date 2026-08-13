{
  fetchPypi,
  lib,
  python313Packages,
}:
python313Packages.buildPythonPackage rec {
  pname = "aiosqlitepool";
  version = "1.0.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-OX95mT1/NKV0CTn7blL/KVY/rVxADvi3CZDmQzGVdAk=";
  };

  build-system = [ python313Packages.setuptools ];
  dependencies = [ python313Packages.aiosqlite ];

  pythonImportsCheck = [ "aiosqlitepool" ];

  meta = {
    description = "Asyncio connection pool for aiosqlite";
    homepage = "https://github.com/slaily/aiosqlitepool";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
