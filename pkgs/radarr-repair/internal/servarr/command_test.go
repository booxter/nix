package servarr

import "testing"

func TestCompletedImportWithoutResult(t *testing.T) {
	t.Parallel()
	command := Command{Status: CommandCompleted}

	disposition, err := ClassifyImportCommand("Lidarr", command, false)
	if err != nil || disposition != ImportCommandCompleted {
		t.Fatalf("disposition = %d, error = %v", disposition, err)
	}
	if _, err := ClassifyImportCommand("Radarr", command, true); err == nil {
		t.Fatal("expected missing Radarr command result to be rejected")
	}
}
