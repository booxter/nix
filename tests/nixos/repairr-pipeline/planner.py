"""Select the manual import offered by Repairr over its normal planner socket."""

import json
import sys
from http.server import BaseHTTPRequestHandler
from socketserver import UnixStreamServer


def movie_plan(request):
    case = request["repair_case"]
    action = "manual_import_file_v1"
    offers = [option for option in case["capabilities"] if option["action"] == action]
    if len(offers) > 1:
        selected = request.get("selected_file_id")
        if selected is None:
            return {
                "action": "no_repair",
                "reason": "ambiguous_file_selection",
                "missing_evidence": ["file_selection"],
                "evidence_refs": [offer["file_id"] for offer in offers],
                "explanation": "Both videos can be imported. Choose the movie file.",
            }
        offers = [offer for offer in offers if offer["file_id"] == selected]

    (offer,) = offers
    return {
        "action": action,
        "capability_id": offer["capability_id"],
        "file_id": offer["file_id"],
        "evidence_refs": [offer["file_id"]],
        "explanation": "Import the video offered for this movie.",
    }


def album_plan(request):
    case = request["repair_case"]
    offers = case["capabilities"]
    if not offers:
        return {
            "action": "no_repair",
            "reason": "no_repair_needed",
            "evidence_refs": [],
            "explanation": "There are no missing tracks to import.",
        }
    if len(offers) > 1:
        selected = request.get("selected_release_id")
        if selected is None:
            return {
                "action": "no_repair",
                "reason": "ambiguous_release",
                "evidence_refs": [offer["capability_id"] for offer in offers],
                "explanation": "The same songs appear on both editions. Choose a release.",
            }
        offers = [offer for offer in offers if offer["release_id"] == selected]

    (offer,) = offers
    tracks = {track["track_id"]: track for track in case["tracks"]}
    # Lidarr assessed the files against the original CD. Match the songs
    # by title and position within the edition the operator selected.
    mappings = []
    for file in case["assessments"]:
        (assessed_id,) = file["track_ids"]
        assessed = tracks[assessed_id]
        (track_id,) = [
            id_
            for id_ in offer["track_ids"]
            if tracks[id_]["title"] == assessed["title"]
            and tracks[id_]["absolute_number"] == assessed["absolute_number"]
        ]
        mappings.append({"artifact_id": file["artifact_id"], "track_id": track_id})
    return {
        "action": offer["action"],
        "capability_id": offer["capability_id"],
        "album_id": offer["album_id"],
        "release_id": offer["release_id"],
        "mappings": mappings,
        "evidence_refs": offer["artifact_ids"],
        "explanation": "Import each file as the missing track identified by Lidarr.",
    }


class Planner(BaseHTTPRequestHandler):
    def address_string(self) -> str:
        return "repairr"

    def do_POST(self) -> None:
        plan = {"/radarr/plan": movie_plan, "/lidarr/plan": album_plan}.get(self.path)
        if plan is None:
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        case = request["repair_case"]
        decision = {
            "schema_version": case["schema_version"],
            "case_id": case["case_id"],
            **plan(request),
        }
        data = json.dumps(decision).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


with UnixStreamServer(sys.argv[1], Planner) as server:
    server.serve_forever()
