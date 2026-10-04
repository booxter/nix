package repair

import (
	"fmt"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
)

func CommandStatus(command servarr.Command, requireResult bool) (ImportStatus, error) {
	disposition, err := servarr.ClassifyImportCommand("Servarr", command, requireResult)
	if err != nil {
		return ImportStatus{}, err
	}

	if disposition == servarr.ImportCommandPending {
		return ImportStatus{}, nil
	}

	return ImportStatus{Failure: fmt.Sprintf("import command %d finished without matching import history: %s", command.ID, command.Message)}, nil
}
