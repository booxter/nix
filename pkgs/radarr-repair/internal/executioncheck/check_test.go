package executioncheck

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/inspection"
)

const (
	executionCaseID = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	executionHash   = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
)

func TestCheckReturnsFreshManualImportAuthorization(t *testing.T) {
	t.Parallel()

	stored := executionAssembly()
	fresh := executionAssembly()
	advanceObservation(&fresh, time.Minute)
	cases := &fakeFreshCases{assembly: fresh}
	outputs := &fakeJoinOutputs{}
	checker := newTestChecker(t, cases, outputs, stored.Request.ObservedAt.Add(time.Hour))

	result, err := checker.Check(
		context.Background(),
		stored,
		executionManualImportDecision(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Accepted() || result.Authorization.ManualImport == nil ||
		result.Authorization.Join != nil {
		t.Fatalf("result = %#v", result)
	}
	if cases.selection.QueueID != 71 {
		t.Fatalf("selected queue ID = %d", cases.selection.QueueID)
	}
	if outputs.calls != 0 {
		t.Fatalf("join output reads = %d", outputs.calls)
	}
}

func TestCheckRequiresAbsentJoinOutput(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		exists   bool
		accepted bool
	}{
		{name: "absent", accepted: true},
		{name: "present", exists: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := executionAssembly()
			fresh := executionAssembly()
			advanceObservation(&fresh, time.Minute)
			outputs := &fakeJoinOutputs{exists: test.exists}
			checker := newTestChecker(
				t,
				&fakeFreshCases{assembly: fresh},
				outputs,
				stored.Request.ObservedAt.Add(time.Hour),
			)

			result, err := checker.Check(
				context.Background(),
				stored,
				executionJoinDecision(),
			)
			if err != nil {
				t.Fatal(err)
			}
			if test.accepted && (!result.Accepted() || result.Authorization.Join == nil) {
				t.Fatalf("result = %#v", result)
			}
			if !test.accepted {
				assertRejected(t, result, JoinOutputPresent)
			}
			if outputs.calls != 1 || outputs.authorization.CaseID != executionCaseID {
				t.Fatalf("join output query = %#v, calls = %d", outputs.authorization, outputs.calls)
			}
		})
	}
}

func TestCheckWaitsForStableImportPendingEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		elapsed  time.Duration
		accepted bool
	}{
		{name: "before interval", elapsed: 29 * time.Minute},
		{name: "at interval", elapsed: 30 * time.Minute, accepted: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := executionAssembly()
			stored.Request.Radarr.Failure.TrackedDownloadState = "importPending"
			stored.LocalSnapshot.Observation.Correlation.Radarr.TrackedDownloadState =
				"importPending"
			fresh := executionAssembly()
			fresh.Request.Radarr.Failure.TrackedDownloadState = "importPending"
			fresh.LocalSnapshot.Observation.Correlation.Radarr.TrackedDownloadState =
				"importPending"
			advanceObservation(&fresh, test.elapsed)
			cases := &fakeFreshCases{assembly: fresh}
			checker := newTestChecker(
				t,
				cases,
				&fakeJoinOutputs{},
				stored.Request.ObservedAt.Add(test.elapsed),
			)

			result, err := checker.Check(
				context.Background(),
				stored,
				executionManualImportDecision(),
			)
			if err != nil {
				t.Fatal(err)
			}
			if test.accepted && !result.Accepted() {
				t.Fatalf("result = %#v", result)
			}
			if !test.accepted {
				assertRejected(t, result, StabilizationPending)
				if cases.calls != 0 {
					t.Fatalf("fresh case reads = %d", cases.calls)
				}
			}
		})
	}
}

func TestCheckRejectsChangedExecutionState(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*casebuilder.Assembly)
		reason RejectionReason
	}{
		{
			name: "planning evidence changed",
			mutate: func(fresh *casebuilder.Assembly) {
				fresh.Request.CaseID =
					"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
			},
			reason: CaseChanged,
		},
		{
			name: "local path changed",
			mutate: func(fresh *casebuilder.Assembly) {
				fresh.LocalSnapshot.Observation.Correlation.DownloadRoot += ".changed"
			},
			reason: CaseChanged,
		},
		{
			name: "bound command changed",
			mutate: func(fresh *casebuilder.Assembly) {
				binding := fresh.LocalSnapshot.ManualImportBindings["capability:manual"]
				binding.File.ReleaseGroup = "OTHER"
				fresh.LocalSnapshot.ManualImportBindings["capability:manual"] = binding
			},
			reason: AuthorizationChanged,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := executionAssembly()
			fresh := executionAssembly()
			advanceObservation(&fresh, time.Minute)
			test.mutate(&fresh)
			checker := newTestChecker(
				t,
				&fakeFreshCases{assembly: fresh},
				&fakeJoinOutputs{},
				stored.Request.ObservedAt.Add(time.Hour),
			)

			result, err := checker.Check(
				context.Background(),
				stored,
				executionManualImportDecision(),
			)
			if err != nil {
				t.Fatal(err)
			}
			assertRejected(t, result, test.reason)
		})
	}
}

func TestCheckRejectsUnavailableOrInvalidCases(t *testing.T) {
	t.Parallel()

	stored := executionAssembly()
	unavailable := &inspection.CandidateUnavailableError{
		QueueID: 71, Reason: inspection.CandidateMissing,
	}
	checker := newTestChecker(
		t,
		&fakeFreshCases{err: unavailable},
		&fakeJoinOutputs{},
		stored.Request.ObservedAt.Add(time.Hour),
	)
	result, err := checker.Check(
		context.Background(),
		stored,
		executionManualImportDecision(),
	)
	if err != nil {
		t.Fatal(err)
	}
	assertRejected(t, result, CaseUnavailable)

	invalidDecision := executionManualImportDecision()
	invalidDecision.ManualImportFile.FileID = "file:other"
	result, err = checker.Check(context.Background(), stored, invalidDecision)
	if err != nil {
		t.Fatal(err)
	}
	assertRejected(t, result, DecisionRejected)
}

func TestCheckKeepsReadFailuresDistinctFromRejections(t *testing.T) {
	t.Parallel()

	stored := executionAssembly()
	readFailure := errors.New("Radarr unavailable")
	checker := newTestChecker(
		t,
		&fakeFreshCases{err: readFailure},
		&fakeJoinOutputs{},
		stored.Request.ObservedAt.Add(time.Hour),
	)
	if _, err := checker.Check(
		context.Background(),
		stored,
		executionManualImportDecision(),
	); !errors.Is(err, readFailure) {
		t.Fatalf("error = %v", err)
	}

	outputFailure := errors.New("worker unavailable")
	checker = newTestChecker(
		t,
		&fakeFreshCases{assembly: executionAssembly()},
		&fakeJoinOutputs{err: outputFailure},
		stored.Request.ObservedAt.Add(time.Hour),
	)
	if _, err := checker.Check(
		context.Background(),
		stored,
		executionJoinDecision(),
	); !errors.Is(err, outputFailure) {
		t.Fatalf("error = %v", err)
	}
}

func newTestChecker(
	t *testing.T,
	cases FreshCaseReader,
	outputs JoinOutputStateReader,
	now time.Time,
) *Checker {
	t.Helper()
	checker, err := New(Dependencies{
		Cases: cases, Clock: fixedClock{now: now}, JoinOutputs: outputs,
		Stabilization: 30 * time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	return checker
}

func assertRejected(t *testing.T, result Result, reason RejectionReason) {
	t.Helper()
	if result.Accepted() || len(result.Rejections) != 1 ||
		result.Rejections[0].Reason != reason {
		t.Fatalf("result = %#v, want rejection %q", result, reason)
	}
}

func executionAssembly() casebuilder.Assembly {
	observedAt := time.Date(2026, time.September, 13, 12, 0, 0, 0, time.UTC)
	movieID := int64(42)
	runtimeMinutes := 60
	first := executionFile("file:first", "part-1.mkv", 100, 1)
	second := executionFile("file:second", "part-2.mkv", 200, 2)
	firstID := string(first.ID)
	firstPath := "/downloads/Example/part-1.mkv"
	secondPath := "/downloads/Example/part-2.mkv"
	return casebuilder.Assembly{
		Request: contracts.RepairCaseV1{
			CaseID: executionCaseID, ObservedAt: observedAt,
			Capabilities: []contracts.Capability{
				{
					Action: contracts.CapabilityActionJoinParts, CapabilityID: "capability:join",
					CandidateFileIDS: []string{string(first.ID), string(second.ID)},
				},
				{
					Action:       contracts.CapabilityActionManualImportFile,
					CapabilityID: "capability:manual", FileID: &firstID,
				},
			},
		},
		LocalSnapshot: casebuilder.LocalSnapshot{
			CaseID: executionCaseID,
			Observation: casebuilder.Observation{
				ObservedAt: observedAt,
				Correlation: controller.DownloadCorrelation{
					DownloadRoot: "/downloads/Example",
					Radarr: controller.RadarrQueueRecord{
						ID: 71, MovieID: &movieID, DownloadID: executionHash,
						TrackedDownloadState: "importBlocked",
					},
				},
				Movie: &controller.RadarrMovie{
					ID: movieID, RuntimeMinutes: &runtimeMinutes,
				},
				Inventory: controller.FileInventory{
					Files: []controller.InventoryFile{first, second},
					Paths: []controller.FilePathMapping{
						{FileID: first.ID, AbsolutePath: firstPath},
						{FileID: second.ID, AbsolutePath: secondPath},
					},
				},
				Probes: []casebuilder.FileProbe{
					{
						FileID: first.ID,
						Outcome: controller.SuccessfulMediaProbe(
							executionProbe(60*60*1_000, 100),
						),
					},
					{
						FileID: second.ID,
						Outcome: controller.SuccessfulMediaProbe(
							executionProbe(60*60*1_000, 200),
						),
					},
				},
			},
			ManualImportBindings: map[string]controller.RadarrManualImportBinding{
				"capability:manual": {
					FileID: first.ID, ExpectedFingerprint: first.Fingerprint,
					ImportMode: controller.RadarrImportModeCopy,
					File: controller.RadarrManualImportCommandFile{
						Path: firstPath, FolderName: "Example",
						Quality: controller.RadarrQualityModel{
							Quality: controller.RadarrQuality{ID: 7, Name: "Bluray-1080p"},
						},
						Languages:    []controller.RadarrLanguage{{ID: 1, Name: "English"}},
						ReleaseGroup: "GROUP", DownloadID: executionHash, MovieID: movieID,
					},
				},
			},
		},
	}
}

func executionFile(
	id controller.FileID,
	name string,
	size int64,
	inode uint64,
) controller.InventoryFile {
	return controller.InventoryFile{
		ID: id, PathComponents: []string{name},
		Fingerprint: controller.FileFingerprint{
			Device: 1, Inode: inode, SizeBytes: size, MTimeNS: 3,
		},
		TorrentFile: &controller.TorrentFileReference{
			LengthBytes: size, BytesCompleted: size, Wanted: true,
		},
	}
}

func executionProbe(durationMS, size int64) controller.ProbeEvidence {
	video := controller.ProbeStreamVideo
	codec := "h264"
	streamDurationMS := durationMS
	width := int64(1_920)
	height := int64(1_080)
	pixelFormat := "yuv420p"
	rate := controller.Rational{Numerator: 24, Denominator: 1}
	timeBase := controller.Rational{Numerator: 1, Denominator: 1_000}
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names: []string{"matroska"}, DurationMS: &durationMS, SizeBytes: &size,
		},
		Streams: []controller.ProbeStream{{
			Index: 0, Kind: &video, CodecName: &codec, DurationMS: &streamDurationMS,
			Width: &width, Height: &height, PixelFormat: &pixelFormat,
			AverageRate: &rate, TimeBase: &timeBase,
		}},
	}
}

func executionManualImportDecision() contracts.RepairDecisionV1 {
	return contracts.RepairDecisionV1{
		Kind: contracts.ActionManualImportFile,
		ManualImportFile: &contracts.ManualImportFileDecision{
			Action: contracts.ManualImportFileDecisionAction(contracts.ActionManualImportFile),
			CaseID: executionCaseID, CapabilityID: "capability:manual", FileID: "file:first",
		},
	}
}

func executionJoinDecision() contracts.RepairDecisionV1 {
	return contracts.RepairDecisionV1{
		Kind: contracts.ActionJoinParts,
		JoinParts: &contracts.JoinDecision{
			Action: contracts.JoinDecisionAction(contracts.ActionJoinParts),
			CaseID: executionCaseID, CapabilityID: "capability:join",
			OrderedFileIDS: []string{"file:first", "file:second"},
		},
	}
}

func advanceObservation(assembly *casebuilder.Assembly, elapsed time.Duration) {
	assembly.Request.ObservedAt = assembly.Request.ObservedAt.Add(elapsed)
	assembly.LocalSnapshot.Observation.ObservedAt =
		assembly.LocalSnapshot.Observation.ObservedAt.Add(elapsed)
}

type fixedClock struct {
	now time.Time
}

func (clock fixedClock) Now() time.Time {
	return clock.now
}

type fakeFreshCases struct {
	assembly  casebuilder.Assembly
	err       error
	selection inspection.Selection
	calls     int
}

func (cases *fakeFreshCases) Inspect(
	_ context.Context,
	selection inspection.Selection,
) (casebuilder.Assembly, error) {
	cases.calls++
	cases.selection = selection
	return cases.assembly, cases.err
}

type fakeJoinOutputs struct {
	exists        bool
	err           error
	authorization decisionpolicy.AuthorizedJoin
	calls         int
}

func (outputs *fakeJoinOutputs) JoinOutputExists(
	_ context.Context,
	authorization decisionpolicy.AuthorizedJoin,
) (bool, error) {
	outputs.calls++
	outputs.authorization = authorization
	return outputs.exists, outputs.err
}
