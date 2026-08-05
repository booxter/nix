from __future__ import annotations


class CollectionFailure(RuntimeError):
    def __init__(self, exit_code: int) -> None:
        super().__init__(f"usage collection failed with exit code {exit_code}")
        self.exit_code = exit_code
