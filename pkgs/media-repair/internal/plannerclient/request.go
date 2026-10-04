package plannerclient

import (
	"encoding/json"

	"github.com/booxter/nix-config/media-repair/internal/planning"
)

type request struct {
	RepairCase json.RawMessage `json:"repair_case"`
	planning.Options
}

func encodeRequest(repairCase json.RawMessage, options planning.Options) ([]byte, error) {
	return json.Marshal(request{RepairCase: repairCase, Options: options})
}
