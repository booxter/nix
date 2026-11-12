import hashlib
import sqlite3
from collections.abc import Iterable
from http.cookiejar import MozillaCookieJar
from pathlib import Path

from atomic_file_writes import atomic_path, write_text_atomic


class State:
    def __init__(self, directory: Path, account: str) -> None:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Keep account names out of filenames and operational output.
        self.scope = hashlib.sha256(account.casefold().encode()).hexdigest()
        self.database = sqlite3.connect(directory / "state.sqlite")
        self.database.execute(
            "CREATE TABLE IF NOT EXISTS imported "
            "(account TEXT, imdb TEXT, PRIMARY KEY (account, imdb))"
        )

    def pending(self, movies: Iterable[str]) -> tuple[str, ...]:
        done = {
            row[0]
            for row in self.database.execute(
                "SELECT imdb FROM imported WHERE account = ?", (self.scope,)
            )
        }
        return tuple(sorted(set(movies) - done))

    def record(self, movies: Iterable[str]) -> None:
        with self.database:
            self.database.executemany(
                "INSERT OR IGNORE INTO imported VALUES (?, ?)",
                ((self.scope, movie) for movie in movies),
            )

    def close(self) -> None:
        self.database.close()


class Cookies:
    def __init__(self, seed: Path, directory: Path) -> None:
        self.path = directory / "cookies.txt"
        self.fingerprint_path = directory / "cookie-seed.sha256"
        self.fingerprint = hashlib.sha256(seed.read_bytes()).hexdigest()
        previous = self.fingerprint_path.read_text() if self.fingerprint_path.exists() else None
        self.jar = MozillaCookieJar()
        source = self.path if previous == self.fingerprint and self.path.exists() else seed
        self.jar.load(str(source), ignore_discard=True)

    def save(self) -> None:
        with atomic_path(self.path, mode=0o600) as temporary:
            self.jar.save(str(temporary), ignore_discard=True)
        write_text_atomic(self.fingerprint_path, self.fingerprint, mode=0o600)
