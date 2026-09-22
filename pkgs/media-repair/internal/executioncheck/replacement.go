package executioncheck

import (
	"github.com/booxter/nix-config/media-repair/internal/casebuilder"
	"github.com/booxter/nix-config/media-repair/internal/controller"
)

// replacementRejection checks Radarr's current assessment of only the files
// selected by the authorized action. The planner does not decide upgrade policy.
func replacementRejection(
	assembly casebuilder.Assembly,
	authorization Authorization,
) (RejectionReason, bool) {
	observation := assembly.LocalSnapshot.Observation
	if observation.Movie == nil || !observation.Movie.HasFile {
		return "", false
	}

	if authorization.ManualImport != nil {
		return rejectionForReplacement(
			replacementForPath(assembly, authorization.ManualImport.File.Path),
		)
	}
	if authorization.Join == nil {
		return UnprovedReplacement, true
	}

	unproved := false
	for _, part := range authorization.Join.OrderedParts {
		path, found := inventoryPath(assembly, part.FileID)
		if !found {
			unproved = true
			continue
		}
		safety := replacementForPath(assembly, path)
		if safety == controller.ReplacementSuperseded {
			return SupersededReplacement, true
		}
		if safety != controller.ReplacementAllowed {
			unproved = true
		}
	}
	if unproved {
		return UnprovedReplacement, true
	}
	return "", false
}

func replacementForPath(
	assembly casebuilder.Assembly,
	path string,
) controller.ReplacementSafety {
	var matched *controller.RadarrManualImport
	for index := range assembly.LocalSnapshot.Observation.ManualImports {
		candidate := &assembly.LocalSnapshot.Observation.ManualImports[index]
		if candidate.Path != path {
			continue
		}
		if matched != nil {
			return controller.ReplacementUnproved
		}
		matched = candidate
	}
	if matched == nil {
		return controller.ReplacementUnproved
	}
	return controller.ClassifyReplacement(
		assembly.LocalSnapshot.Observation.Movie,
		*matched,
	)
}

func inventoryPath(
	assembly casebuilder.Assembly,
	fileID controller.FileID,
) (string, bool) {
	path := ""
	found := false
	for _, candidate := range assembly.LocalSnapshot.Observation.Inventory.Paths {
		if candidate.FileID != fileID {
			continue
		}
		if found {
			return "", false
		}
		path = candidate.AbsolutePath
		found = true
	}
	return path, found
}

func rejectionForReplacement(
	safety controller.ReplacementSafety,
) (RejectionReason, bool) {
	switch safety {
	case controller.ReplacementAllowed:
		return "", false
	case controller.ReplacementSuperseded:
		return SupersededReplacement, true
	default:
		return UnprovedReplacement, true
	}
}
