import json
import plistlib
import subprocess
import sys
from pathlib import Path


def check_case(case, inherited):
    job = plistlib.loads(Path(case["plist"]).read_bytes())
    environment = inherited | job.get("EnvironmentVariables", {})
    expected = inherited | case["expectedEnvironment"]

    if "NIX_SSL_CERT_FILE" not in expected and "SSL_CERT_FILE" not in expected:
        expected["NIX_SSL_CERT_FILE"] = case["defaultBundle"]

    # Apply launchd's environment and argv semantics without loading live jobs.
    arguments = job["ProgramArguments"]
    with subprocess.Popen(
        arguments,
        executable=job.get("Program", arguments[0]),
        env=environment,
        stdout=subprocess.PIPE,
    ) as process:
        output, _ = process.communicate(timeout=30)
        assert process.returncode == 23, (
            f"{case['name']}: expected exit status 23, got {process.returncode}"
        )

    fields = output.decode().split("\0")
    expected_fields = [str(process.pid), *case["expectedArgv"]]

    expected_fields.extend(
        f"{name}={expected[name]}" if name in expected else name
        for name in ("NIX_SSL_CERT_FILE", "SSL_CERT_FILE")
    )

    # Splitting the probe's trailing NUL produces one final empty field.
    expected_fields.append("")
    assert fields == expected_fields, (
        f"{case['name']} with inherited environment {inherited!r}:\n"
        f"expected: {expected_fields!r}\n"
        f"actual:   {fields!r}"
    )


def main():
    cases = json.loads(Path(sys.argv[1]).read_text())
    inherited_environments = [
        {},
        {"NIX_SSL_CERT_FILE": "/inherited/nix.pem"},
        {"SSL_CERT_FILE": "/inherited/ssl.pem"},
        {"NIX_SSL_CERT_FILE": ""},
        {"SSL_CERT_FILE": ""},
        {"NIX_SSL_CERT_FILE": "/inherited/nix.pem", "SSL_CERT_FILE": "/inherited/ssl.pem"},
    ]

    for case in cases:
        for inherited in inherited_environments:
            check_case(case, inherited)

    print(f"Checked {len(cases) * len(inherited_environments)} launchd certificate cases")


if __name__ == "__main__":
    main()
