package mediaoperation

import (
	"fmt"

	"github.com/booxter/nix-config/media-repair/internal/controller"
	"github.com/booxter/nix-config/media-repair/internal/decisionpolicy"
)

type Transform struct {
	JobID   int64
	Attempt int64
	Paths   map[controller.FileID]string
	Join    *decisionpolicy.AuthorizedJoin  `json:",omitempty"`
	Bluray  *decisionpolicy.AuthorizedRemux `json:",omitempty"`
	DVD     *decisionpolicy.AuthorizedDVD   `json:",omitempty"`
}

func (request Transform) ID() string {
	return fmt.Sprintf("job-%d-attempt-%d", request.JobID, request.Attempt)
}

type Output struct {
	Path        string
	Fingerprint string
	Evidence    controller.ProbeEvidence
}
