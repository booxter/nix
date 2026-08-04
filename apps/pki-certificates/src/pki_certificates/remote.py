from __future__ import annotations

import sys
from collections.abc import Sequence

from pydantic import ValidationError
from sops_tools.errors import ToolError
from sops_tools.process import SubprocessRunner

from .issuer import StepCaIssuer
from .models import CertificateRequest


def main(argv: Sequence[str] | None = None) -> int:
    if argv:
        raise SystemExit("remote helper accepts its request on stdin")
    try:
        request = CertificateRequest.model_validate_json(sys.stdin.read())
        material = StepCaIssuer(
            SubprocessRunner(
                {
                    "HOME": "/var/lib/step-ca",
                    "STEPPATH": "/var/lib/step-ca",
                }
            )
        ).issue(request)
    except (ValidationError, ToolError) as error:
        raise SystemExit(str(error)) from error
    print(material.model_dump_json())
    return 0
