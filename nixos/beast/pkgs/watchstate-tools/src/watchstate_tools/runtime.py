from __future__ import annotations

from typing import Protocol

from podman import PodmanClient


class ContainerRuntime(Protocol):
    def trigger_backup(self) -> None: ...


class PodmanRuntime:
    def __init__(self, socket_url: str, container: str) -> None:
        self.socket_url = socket_url
        self.container = container

    def trigger_backup(self) -> None:
        try:
            with PodmanClient(base_url=self.socket_url, timeout=120) as client:
                container = client.containers.get(self.container)
                exit_code, output = container.exec_run(
                    [
                        "/opt/bin/console",
                        "state:backup",
                        "--keep",
                        "--sync-requests",
                        "--no-interaction",
                        "-v",
                    ]
                )
        except Exception as error:
            raise RuntimeError("Unable to trigger the WatchState container backup") from error
        if exit_code != 0:
            detail = output.decode(errors="replace") if isinstance(output, bytes) else str(output)
            raise RuntimeError(
                f"WatchState container backup failed with exit code {exit_code}: {detail}"
            )
