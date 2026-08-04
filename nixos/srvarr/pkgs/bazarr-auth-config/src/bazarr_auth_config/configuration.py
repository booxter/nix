from __future__ import annotations

import os
from io import StringIO
from pathlib import Path

from atomic_file_writes import write_text_atomic
from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap


class ConfigurationError(ValueError):
    pass


def yaml_codec() -> YAML:
    codec = YAML(typ="rt")
    codec.preserve_quotes = True
    return codec


def load_configuration(path: Path, codec: YAML) -> CommentedMap:
    if not path.exists() or path.stat().st_size == 0:
        return CommentedMap()
    with path.open(encoding="utf-8") as stream:
        loaded = codec.load(stream)
    if not isinstance(loaded, CommentedMap):
        raise ConfigurationError("Bazarr configuration root must be a mapping")
    return loaded


def disable_local_auth(configuration: CommentedMap) -> None:
    auth = configuration.get("auth")
    if not isinstance(auth, CommentedMap):
        auth = CommentedMap()
        configuration["auth"] = auth
    auth["type"] = None
    auth["username"] = ""
    auth["password"] = ""


def render_configuration(configuration: CommentedMap, codec: YAML) -> str:
    output = StringIO()
    codec.dump(configuration, output)
    return output.getvalue()


def reconcile(path: Path, *, uid: int, gid: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chown(path.parent, uid, gid)
    path.parent.chmod(0o700)
    codec = yaml_codec()
    configuration = load_configuration(path, codec)
    disable_local_auth(configuration)
    write_text_atomic(
        path,
        render_configuration(configuration, codec),
        mode=0o600,
        uid=uid,
        gid=gid,
    )
