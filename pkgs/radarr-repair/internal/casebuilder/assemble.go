package casebuilder

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/mkvmerge"
)

const opaqueIDDomain = "radarr-repair-opaque-id-v1\x00"

type FileProbe struct {
	FileID  controller.FileID
	Outcome controller.MediaProbeOutcome
}

type Observation struct {
	ObservedAt      time.Time
	Correlation     controller.DownloadCorrelation
	Movie           *controller.RadarrMovie
	History         []controller.RadarrHistoryEvent
	ManualImports   []controller.RadarrManualImport
	Inventory       controller.FileInventory
	Probes          []FileProbe
	BluRayPlaylists []mkvmerge.Candidate
}

// LocalSnapshot retains controller-only observations needed to audit and later
// execute a decision. It must never be sent to the planner.
type LocalSnapshot struct {
	CaseID               string
	Observation          Observation
	ManualImportBindings map[string]controller.RadarrManualImportBinding
}

type Assembly struct {
	Request        contracts.RepairCaseV2
	EncodedRequest []byte
	LocalSnapshot  LocalSnapshot
}

func Assemble(observation Observation) (Assembly, error) {
	if observation.ObservedAt.IsZero() {
		return Assembly{}, fmt.Errorf("observation time is missing")
	}
	if !observation.Correlation.Eligible() {
		return Assembly{}, fmt.Errorf("download correlation is ineligible")
	}
	if observation.Movie != nil && (observation.Correlation.Radarr.MovieID == nil ||
		*observation.Correlation.Radarr.MovieID != observation.Movie.ID) {
		return Assembly{}, fmt.Errorf("Radarr movie does not match the queue record")
	}

	inventoryFiles, paths, err := indexInventory(observation.Inventory)
	if err != nil {
		return Assembly{}, err
	}
	probes, err := indexProbes(observation.Probes)
	if err != nil {
		return Assembly{}, err
	}

	assessments := controller.ClassifyMediaFiles(observation.Inventory)
	candidateFileIDs := make([]string, 0, len(assessments))
	files := make([]contracts.FileElement, 0, len(assessments))
	for _, assessment := range assessments {
		file := assessment.File
		if _, ok := paths[file.ID]; !ok {
			return Assembly{}, fmt.Errorf("inventory file %q has no local path", file.ID)
		}
		outcome, ok := probes[file.ID]
		if !ok {
			return Assembly{}, fmt.Errorf("inventory file %q has no probe outcome", file.ID)
		}
		mapped, mapErr := mapFile(assessment, outcome)
		if mapErr != nil {
			return Assembly{}, fmt.Errorf("map file %q: %w", file.ID, mapErr)
		}
		if assessment.ProbeCandidate() &&
			mapped.Probe.Status == contracts.Ok &&
			controller.SupportsJoinPartsPath(file.PathComponents) {
			candidateFileIDs = append(candidateFileIDs, mapped.FileID)
		}
		files = append(files, mapped)
	}
	if len(probes) != len(files) {
		return Assembly{}, fmt.Errorf("probe outcomes do not exactly match inventory files")
	}

	downloadRef := opaqueID("download", observation.Correlation.Download.ID)
	manualImports, err := matchManualImports(observation.ManualImports, inventoryFiles, paths)
	if err != nil {
		return Assembly{}, err
	}
	radarrEvidence, err := mapRadarr(
		observation, downloadRef, manualImports,
	)
	if err != nil {
		return Assembly{}, err
	}
	manualImportCapabilities, manualImportBindings, err := bindManualImportCapabilities(
		manualImports, observation.History,
	)
	if err != nil {
		return Assembly{}, err
	}
	bluRayCapabilities, err := bindBluRayCapabilities(observation.BluRayPlaylists, inventoryFiles)
	if err != nil {
		return Assembly{}, err
	}
	capabilities := append(joinCapabilities(candidateFileIDs), manualImportCapabilities...)
	capabilities = append(capabilities, bluRayCapabilities...)
	request := contracts.RepairCaseV2{
		SchemaVersion: contracts.RadarrRepairV2,
		ObservedAt:    observation.ObservedAt.UTC(),
		Radarr:        radarrEvidence,
		Download:      mapDownload(observation.Correlation.Download, downloadRef, len(files)),
		Files:         files,
		Capabilities:  capabilities,
	}
	if err := rejectLocalValues(request, observation); err != nil {
		return Assembly{}, err
	}
	request.CaseID, err = contracts.CalculateCaseID(request)
	if err != nil {
		return Assembly{}, fmt.Errorf("calculate repair case ID: %w", err)
	}
	encoded, err := contracts.EncodeCase(request)
	if err != nil {
		return Assembly{}, fmt.Errorf("encode repair case: %w", err)
	}

	return Assembly{
		Request:        request,
		EncodedRequest: encoded,
		LocalSnapshot: LocalSnapshot{
			CaseID:               request.CaseID,
			Observation:          observation,
			ManualImportBindings: manualImportBindings,
		},
	}, nil
}

func joinCapabilities(candidateFileIDs []string) []contracts.Capability {
	capabilities := make([]contracts.Capability, 0, 1)
	if len(candidateFileIDs) < 2 {
		return capabilities
	}

	identity := make([]string, 1, len(candidateFileIDs)+1)
	identity[0] = string(contracts.CapabilityActionJoinParts)
	identity = append(identity, candidateFileIDs...)
	capabilities = append(capabilities, contracts.Capability{
		Action:           contracts.CapabilityActionJoinParts,
		CandidateFileIDS: clone(candidateFileIDs),
		CapabilityID:     opaqueID("capability", identity...),
	})
	return capabilities
}

func bindManualImportCapabilities(
	matches []manualImportMatch,
	history []controller.RadarrHistoryEvent,
) ([]contracts.Capability, map[string]controller.RadarrManualImportBinding, error) {
	capabilities := make([]contracts.Capability, 0, len(matches))
	bindings := make(map[string]controller.RadarrManualImportBinding, len(matches))
	for _, match := range matches {
		binding, ok := controller.BindRadarrManualImportFile(
			match.File, match.AbsolutePath, match.Import, history,
		)
		if !ok {
			continue
		}
		capabilityID := manualImportCapabilityID(binding)
		if _, duplicate := bindings[capabilityID]; duplicate {
			return nil, nil, fmt.Errorf("duplicate manual import capability %q", capabilityID)
		}
		bindings[capabilityID] = binding
		fileID := string(binding.FileID)
		capabilities = append(capabilities, contracts.Capability{
			Action:       contracts.CapabilityActionManualImportFile,
			CapabilityID: capabilityID,
			FileID:       &fileID,
		})
	}
	return capabilities, bindings, nil
}

func manualImportCapabilityID(binding controller.RadarrManualImportBinding) string {
	identity := []string{
		string(contracts.CapabilityActionManualImportFile),
		string(binding.FileID),
		binding.ExpectedFingerprint.Fingerprint(),
		string(binding.ImportMode),
		binding.File.Path,
		binding.File.FolderName,
		strconv.FormatInt(binding.File.Quality.Quality.ID, 10),
		binding.File.Quality.Quality.Name,
		binding.File.Quality.Quality.Source,
		strconv.Itoa(binding.File.Quality.Quality.Resolution),
		binding.File.Quality.Quality.Modifier,
	}
	if binding.File.Quality.Revision == nil {
		identity = append(identity, "revision:absent")
	} else {
		revision := binding.File.Quality.Revision
		identity = append(identity,
			"revision:present",
			strconv.FormatInt(revision.Version, 10),
			strconv.FormatInt(revision.Real, 10),
			strconv.FormatBool(revision.IsRepack),
		)
	}
	identity = append(identity, strconv.Itoa(len(binding.File.Languages)))
	for _, language := range binding.File.Languages {
		identity = append(identity, strconv.FormatInt(language.ID, 10), language.Name)
	}
	identity = append(identity,
		binding.File.ReleaseGroup,
		strconv.FormatInt(binding.File.IndexerFlags, 10),
		binding.File.DownloadID,
		strconv.FormatInt(binding.File.MovieID, 10),
	)
	return opaqueID("capability", identity...)
}

func indexInventory(
	inventory controller.FileInventory,
) (map[controller.FileID]controller.InventoryFile, map[controller.FileID]string, error) {
	files := make(map[controller.FileID]struct{}, len(inventory.Files))
	indexedFiles := make(map[controller.FileID]controller.InventoryFile, len(inventory.Files))
	for _, file := range inventory.Files {
		if file.ID == "" {
			return nil, nil, fmt.Errorf("inventory contains a file without an ID")
		}
		if _, duplicate := files[file.ID]; duplicate {
			return nil, nil, fmt.Errorf("inventory contains duplicate file ID %q", file.ID)
		}
		files[file.ID] = struct{}{}
		indexedFiles[file.ID] = file
	}

	paths := make(map[controller.FileID]string, len(inventory.Paths))
	for _, mapping := range inventory.Paths {
		if _, known := files[mapping.FileID]; !known {
			return nil, nil, fmt.Errorf("local path refers to unknown file ID %q", mapping.FileID)
		}
		if _, duplicate := paths[mapping.FileID]; duplicate {
			return nil, nil, fmt.Errorf("inventory contains duplicate path for file ID %q", mapping.FileID)
		}
		if mapping.AbsolutePath == "" {
			return nil, nil, fmt.Errorf("file %q has an empty local path", mapping.FileID)
		}
		paths[mapping.FileID] = mapping.AbsolutePath
	}
	return indexedFiles, paths, nil
}

func indexProbes(probes []FileProbe) (map[controller.FileID]controller.MediaProbeOutcome, error) {
	indexed := make(map[controller.FileID]controller.MediaProbeOutcome, len(probes))
	for _, probe := range probes {
		if probe.FileID == "" {
			return nil, fmt.Errorf("probe has no file ID")
		}
		if _, duplicate := indexed[probe.FileID]; duplicate {
			return nil, fmt.Errorf("duplicate probe for file ID %q", probe.FileID)
		}
		indexed[probe.FileID] = probe.Outcome
	}
	return indexed, nil
}

func mapDownload(download controller.Download, downloadRef string, fileCount int) contracts.Download {
	completedAt := utcTime(download.CompletedAt)
	return contracts.Download{
		SourceType:       contracts.SourceType(download.SourceType),
		Client:           contracts.Client(download.Client),
		ContentOwnership: contracts.ContentOwnership(download.ContentOwnership),
		DownloadRef:      downloadRef,
		Name:             download.Name,
		TotalSizeBytes:   download.TotalSizeBytes,
		FileCount:        int64(fileCount),
		IsComplete:       download.Complete,
		CompletedAt:      completedAt,
		Labels:           clone(download.Labels),
	}
}

func opaqueID(kind string, values ...string) string {
	digest := sha256.New()
	digest.Write([]byte(opaqueIDDomain))
	digest.Write([]byte(kind))
	for _, value := range values {
		digest.Write([]byte{0})
		digest.Write([]byte(strconv.Itoa(len(value))))
		digest.Write([]byte{0})
		digest.Write([]byte(value))
	}
	return kind + ":" + hex.EncodeToString(digest.Sum(nil))
}

func rejectLocalValues(request contracts.RepairCaseV2, observation Observation) error {
	data, err := json.Marshal(request)
	if err != nil {
		return fmt.Errorf("inspect planner request for local values: %w", err)
	}
	encoded := string(data)
	for _, path := range localPaths(observation) {
		if path != "" && strings.Contains(encoded, path) {
			return fmt.Errorf("planner request contains a local path")
		}
	}
	for _, identifier := range []string{
		observation.Correlation.Radarr.DownloadID,
		observation.Correlation.Download.ID,
	} {
		if identifier != "" && strings.Contains(strings.ToLower(encoded), strings.ToLower(identifier)) {
			return fmt.Errorf("planner request contains a raw download identifier")
		}
	}
	return nil
}

func localPaths(observation Observation) []string {
	paths := []string{
		observation.Correlation.DownloadRoot,
		observation.Correlation.Radarr.OutputPath,
		observation.Correlation.Download.OutputPath,
	}
	for _, file := range observation.Correlation.Download.Files {
		paths = append(paths, file.Path)
	}
	for _, mapping := range observation.Inventory.Paths {
		paths = append(paths, mapping.AbsolutePath)
	}
	for _, item := range observation.ManualImports {
		paths = append(paths, item.Path)
	}
	return paths
}

func utcTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	utc := value.UTC()
	return &utc
}

func clone[T any](values []T) []T {
	result := make([]T, len(values))
	copy(result, values)
	return result
}
