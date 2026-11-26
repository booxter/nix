"""Select the manual import offered by Repairr over its normal planner socket."""

import json
import sys
from http.server import BaseHTTPRequestHandler
from socketserver import UnixStreamServer


class Planner(BaseHTTPRequestHandler):
    def address_string(self) -> str:
        return "repairr"

    def do_POST(self) -> None:
        if self.path != "/radarr/plan":
            self.send_error(404)
            return

        request = self.rfile.read(int(self.headers["Content-Length"]))
        case = json.loads(request)["repair_case"]
        action = "manual_import_file_v1"
        (offer,) = [option for option in case["capabilities"] if option["action"] == action]
        decision = {
            "schema_version": case["schema_version"],
            "case_id": case["case_id"],
            "action": action,
            "capability_id": offer["capability_id"],
            "file_id": offer["file_id"],
            "evidence_refs": [offer["file_id"]],
            "explanation": "Import the video offered for this movie.",
        }
        data = json.dumps(decision).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


with UnixStreamServer(sys.argv[1], Planner) as server:
    server.serve_forever()
