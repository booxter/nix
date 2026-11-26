package joinstage

import workercontracts "github.com/booxter/nix-config/media-repair/worker/contracts"

type Specification struct {
	ArtifactID          string
	RootID              string
	Parts               []Part
	OutputContainer     workercontracts.OutputContainer
	ExpectedSourceBytes int64
}

type Part struct {
	PathComponents      []string
	ExpectedFingerprint string
}
