from __future__ import annotations

import argparse
import asyncio
import socket
import sys
from collections.abc import Callable, Sequence
from typing import NoReturn, Protocol

import uvicorn
from fastapi import FastAPI

from .api import ApiLimits, ContractEndpoint, create_app
from .lidarr_contracts import decode_case as decode_lidarr_case
from .lidarr_contracts import encode_decision as encode_lidarr_decision
from .lidarr_planning import LidarrPlanner
from .model_runtime import (
    ModelArguments,
    ModelFactory,
    RuntimeDecisionModel,
    add_model_arguments,
    close_model,
    create_model,
    settings_from_arguments,
)
from .planning import Planner


class Arguments(ModelArguments):
    socket_fd: int
    planning_timeout_seconds: float


class ServerRunner(Protocol):
    async def serve(self, app: FastAPI, socket_fd: int) -> None: ...


class UvicornServer(Protocol):
    async def serve(self) -> None: ...


UvicornServerFactory = Callable[[uvicorn.Config], UvicornServer]


class ServerConfigurationError(ValueError):
    """The inherited service socket is absent or unsafe."""


def _socket_fd(value: str) -> int:
    result = int(value)
    if result < 0:
        raise argparse.ArgumentTypeError("socket descriptor must not be negative")
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="radarr-repair-planner-serve")
    add_model_arguments(result)
    result.add_argument("--socket-fd", required=True, type=_socket_fd)
    result.add_argument("--planning-timeout-seconds", required=True, type=float)
    return result


def validate_socket(socket_fd: int) -> None:
    try:
        with socket.fromfd(socket_fd, socket.AF_UNIX, socket.SOCK_STREAM) as inherited:
            socket_type = inherited.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE)
            accepting = inherited.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN)
            address = inherited.getsockname()
    except OSError as error:
        raise ServerConfigurationError("failed to inspect inherited socket") from error
    if socket_type != socket.SOCK_STREAM or accepting != 1:
        raise ServerConfigurationError("inherited socket must be a listening stream socket")
    if not isinstance(address, str | bytes) or not address:
        raise ServerConfigurationError("inherited socket must be a named Unix socket")


class UvicornServerRunner:
    def __init__(self, server_factory: UvicornServerFactory = uvicorn.Server) -> None:
        self._server_factory = server_factory

    async def serve(self, app: FastAPI, socket_fd: int) -> None:
        validate_socket(socket_fd)
        configuration = uvicorn.Config(
            app,
            fd=socket_fd,
            interface="asgi3",
            loop="asyncio",
            proxy_headers=False,
            server_header=False,
            timeout_graceful_shutdown=30,
            workers=1,
        )
        await self._server_factory(configuration).serve()


async def _serve(
    arguments: Arguments,
    model_factory: ModelFactory,
    server_runner: ServerRunner,
) -> None:
    settings = settings_from_arguments(arguments)
    limits = ApiLimits(planning_timeout_seconds=arguments.planning_timeout_seconds)
    model: RuntimeDecisionModel | None = None
    try:
        model = model_factory(settings, None)
        app = create_app(
            Planner(model),
            limits,
            {
                "/lidarr/v2/repair-plans": ContractEndpoint(
                    planner=LidarrPlanner(model),
                    decode_case=decode_lidarr_case,
                    encode_decision=encode_lidarr_decision,
                )
            },
        )
        await server_runner.serve(app, arguments.socket_fd)
    finally:
        await close_model(model)


def main(
    argv: Sequence[str] | None = None,
    model_factory: ModelFactory = create_model,
    server_runner: ServerRunner | None = None,
) -> int:
    arguments = parser().parse_args(argv, namespace=Arguments())
    runner = server_runner if server_runner is not None else UvicornServerRunner()
    try:
        asyncio.run(_serve(arguments, model_factory, runner))
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


def entrypoint() -> NoReturn:
    raise SystemExit(main())
