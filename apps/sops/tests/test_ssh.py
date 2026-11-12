from __future__ import annotations

from sops_tools.ssh import forwarding_environment


def test_local_operator_supplies_its_own_service() -> None:
    environment = forwarding_environment({}, local_socket="/local/sops.sock", connection_id="first")
    assert environment["SOPS_SSH_SOURCE_SOCKET"] == "/local/sops.sock"


def test_onward_connection_preserves_origin_and_gets_its_own_endpoint() -> None:
    values = {
        "SSH_CONNECTION": "client 123 server 22",
        "SOPS_KEYSERVICE": "unix:///forwarded/origin.sock",
        "SOPS_SSH_CONNECTION": "previous",
    }
    first = forwarding_environment(values, local_socket="/local/sops.sock", connection_id="first")
    second = forwarding_environment(values, local_socket="/local/sops.sock", connection_id="second")
    assert first["SOPS_SSH_SOURCE_SOCKET"] == second["SOPS_SSH_SOURCE_SOCKET"]
    assert first["SOPS_SSH_SOURCE_SOCKET"] == "/forwarded/origin.sock"
    assert first["SOPS_SSH_CONNECTION"] != second["SOPS_SSH_CONNECTION"]


def test_remote_session_without_forwarding_does_not_use_remote_hardware() -> None:
    environment = forwarding_environment(
        {"SSH_CONNECTION": "client 123 server 22", "SOPS_SSH_SOURCE_SOCKET": "/stale.sock"},
        local_socket="/local/sops.sock",
        connection_id="first",
    )
    assert "SOPS_SSH_SOURCE_SOCKET" not in environment


def test_non_unix_service_is_not_replaced_by_local_hardware() -> None:
    environment = forwarding_environment(
        {"SOPS_KEYSERVICE": "tcp://localhost:5000"},
        local_socket="/local/sops.sock",
        connection_id="first",
    )
    assert "SOPS_SSH_SOURCE_SOCKET" not in environment


def test_non_operator_has_no_local_service() -> None:
    assert forwarding_environment({}, local_socket=None, connection_id="first") == {}
