package executioncheck

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/booxter/nix-config/radarr-repair/contracts"
	"github.com/booxter/nix-config/radarr-repair/internal/casebuilder"
	"github.com/booxter/nix-config/radarr-repair/internal/casestore"
	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	"github.com/booxter/nix-config/radarr-repair/internal/inspection"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
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
	executions := &fakeJoinExecutions{}
	checker := newTestChecker(t, cases, executions, stored.Request.ObservedAt.Add(time.Hour))

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
	if executions.calls != 0 {
		t.Fatalf("join execution reads = %d", executions.calls)
	}
}

func TestCheckExplainsRejectedManualImportDecision(t *testing.T) {
	t.Parallel()

	stored := executionAssembly()
	runtimeMinutes := 97
	stored.LocalSnapshot.Observation.Movie.RuntimeMinutes = &runtimeMinutes
	checker := newTestChecker(
		t, &fakeFreshCases{}, &fakeJoinExecutions{}, stored.Request.ObservedAt.Add(time.Hour),
	)
	result, err := checker.Check(context.Background(), stored, executionManualImportDecision())
	if err != nil {
		t.Fatal(err)
	}
	assertRejected(t, result, DecisionRejected)
	if got := result.Rejections[0].DecisionReason; got != "runtime_mismatch" {
		t.Fatalf("decision reason = %q, want runtime_mismatch", got)
	}
}

func TestCheckRequiresAbsentJoinExecution(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		state    workercontracts.InspectJoinState
		accepted bool
	}{
		{name: "absent", state: workercontracts.InspectJoinAbsent, accepted: true},
		{name: "prepared", state: workercontracts.InspectJoinPrepared},
		{name: "staged", state: workercontracts.InspectJoinStaged},
		{name: "published", state: workercontracts.InspectJoinPublished},
		{name: "discarded", state: workercontracts.InspectJoinDiscarded},
		{name: "failed", state: workercontracts.InspectJoinFailed},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := executionAssembly()
			fresh := executionAssembly()
			advanceObservation(&fresh, time.Minute)
			executions := &fakeJoinExecutions{state: test.state}
			checker := newTestChecker(
				t,
				&fakeFreshCases{assembly: fresh},
				executions,
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
				assertRejected(t, result, JoinExecutionPresent)
			}
			validation := decisionpolicy.ValidateJoin(fresh, executionJoinDecision())
			if !validation.Accepted() {
				t.Fatalf("join validation = %#v", validation)
			}
			wantID, identityErr := casestore.JoinExecutionID(*validation.Authorized)
			if identityErr != nil {
				t.Fatal(identityErr)
			}
			if executions.calls != 1 || executions.executionID != wantID {
				t.Fatalf(
					"join execution ID = %q, want %q; calls = %d",
					executions.executionID,
					wantID,
					executions.calls,
				)
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
				&fakeJoinExecutions{},
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
				assessment := result.Rejections[0].Stabilization
				if assessment == nil || assessment.ObservedAt != stored.Request.ObservedAt ||
					assessment.CheckedAt != stored.Request.ObservedAt.Add(test.elapsed) ||
					assessment.RequiredAge != 30*time.Minute ||
					assessment.ActualAge != test.elapsed {
					t.Fatalf("stabilization assessment = %#v", assessment)
				}
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
				&fakeJoinExecutions{},
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

func TestCheckAllowsReplacementAfterRadarrCompletedComparison(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name     string
		decision contracts.RepairDecisionV3
	}{
		{"manual import", executionManualImportDecision()},
		{"join", executionJoinDecision()},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := executionAssembly()
			setReplacementEvidence(&stored, map[controller.FileID][]controller.RadarrManualImportRejectionReason{
				"file:first":  {controller.RejectionMultiPartMovie},
				"file:second": {controller.RejectionMultiPartMovie},
			})
			fresh := executionAssembly()
			setReplacementEvidence(&fresh, map[controller.FileID][]controller.RadarrManualImportRejectionReason{
				"file:first":  {controller.RejectionMultiPartMovie},
				"file:second": {controller.RejectionMultiPartMovie},
			})
			advanceObservation(&fresh, time.Minute)
			checker := newTestChecker(
				t,
				&fakeFreshCases{assembly: fresh},
				&fakeJoinExecutions{},
				stored.Request.ObservedAt.Add(time.Hour),
			)

			result, err := checker.Check(context.Background(), stored, test.decision)
			if err != nil {
				t.Fatal(err)
			}
			if !result.Accepted() {
				t.Fatalf("result = %#v", result)
			}
		})
	}
}

func TestCheckRejectsUnsafeReplacement(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		decision contracts.RepairDecisionV3
		evidence map[controller.FileID][]controller.RadarrManualImportRejectionReason
		reason   RejectionReason
	}{
		{
			name: "manual import downgrade", decision: executionManualImportDecision(),
			evidence: map[controller.FileID][]controller.RadarrManualImportRejectionReason{
				"file:first": {controller.RejectionNotQualityUpgrade},
			},
			reason: SupersededReplacement,
		},
		{
			name: "manual import incomplete comparison", decision: executionManualImportDecision(),
			evidence: map[controller.FileID][]controller.RadarrManualImportRejectionReason{
				"file:first": {controller.RejectionUnableToParse},
			},
			reason: UnprovedReplacement,
		},
		{
			name: "join part missing comparison", decision: executionJoinDecision(),
			evidence: map[controller.FileID][]controller.RadarrManualImportRejectionReason{
				"file:first": {controller.RejectionMultiPartMovie},
			},
			reason: UnprovedReplacement,
		},
		{
			name: "join downgrade takes priority", decision: executionJoinDecision(),
			evidence: map[controller.FileID][]controller.RadarrManualImportRejectionReason{
				"file:second": {controller.RejectionNotCustomFormatUpgrade},
			},
			reason: SupersededReplacement,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			stored := executionAssembly()
			setReplacementEvidence(&stored, test.evidence)
			fresh := executionAssembly()
			setReplacementEvidence(&fresh, test.evidence)
			advanceObservation(&fresh, time.Minute)
			checker := newTestChecker(
				t,
				&fakeFreshCases{assembly: fresh},
				&fakeJoinExecutions{},
				stored.Request.ObservedAt.Add(time.Hour),
			)

			result, err := checker.Check(context.Background(), stored, test.decision)
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
		&fakeJoinExecutions{},
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
		&fakeJoinExecutions{},
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
		&fakeJoinExecutions{err: outputFailure},
		stored.Request.ObservedAt.Add(time.Hour),
	)
	if _, err := checker.Check(
		context.Background(),
		stored,
		executionJoinDecision(),
	); !errors.Is(err, outputFailure) {
		t.Fatalf("error = %v", err)
	}

	checker = newTestChecker(
		t,
		&fakeFreshCases{assembly: executionAssembly()},
		&fakeJoinExecutions{failure: true},
		stored.Request.ObservedAt.Add(time.Hour),
	)
	if _, err := checker.Check(
		context.Background(),
		stored,
		executionJoinDecision(),
	); err == nil {
		t.Fatal("worker inspection failure was accepted")
	}
}

func newTestChecker(
	t *testing.T,
	cases FreshCaseReader,
	executions JoinExecutionStateReader,
	now time.Time,
) *Checker {
	t.Helper()
	checker, err := New(Dependencies{
		Cases: cases, Clock: fixedClock{now: now}, JoinExecutions: executions,
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
		Request: contracts.RepairCaseV3{
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
		DownloadFile: &controller.DownloadFileReference{
			LengthBytes: size, BytesCompleted: size, Selected: true,
		},
	}
}

func setReplacementEvidence(
	assembly *casebuilder.Assembly,
	evidence map[controller.FileID][]controller.RadarrManualImportRejectionReason,
) {
	assembly.LocalSnapshot.Observation.Movie.HasFile = true
	assembly.LocalSnapshot.Observation.ManualImports = nil
	for _, mapping := range assembly.LocalSnapshot.Observation.Inventory.Paths {
		reasons, included := evidence[mapping.FileID]
		if !included {
			continue
		}
		rejections := make([]controller.RadarrManualImportRejection, len(reasons))
		for index, reason := range reasons {
			rejections[index] = controller.RadarrManualImportRejection{
				Code: reason, Reason: string(reason),
			}
		}
		assembly.LocalSnapshot.Observation.ManualImports = append(
			assembly.LocalSnapshot.Observation.ManualImports,
			controller.RadarrManualImport{Path: mapping.AbsolutePath, Rejections: rejections},
		)
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

func executionManualImportDecision() contracts.RepairDecisionV3 {
	return contracts.RepairDecisionV3{
		Kind: contracts.ActionManualImportFile,
		ManualImportFile: &contracts.ManualImportFileDecision{
			Action: contracts.ManualImportFileDecisionAction(contracts.ActionManualImportFile),
			CaseID: executionCaseID, CapabilityID: "capability:manual", FileID: "file:first",
		},
	}
}

func executionJoinDecision() contracts.RepairDecisionV3 {
	return contracts.RepairDecisionV3{
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

type fakeJoinExecutions struct {
	state       workercontracts.InspectJoinState
	failure     bool
	err         error
	executionID string
	calls       int
}

func (executions *fakeJoinExecutions) InspectJoin(
	_ context.Context,
	executionID string,
) (workercontracts.InspectJoinResponseV1, error) {
	executions.calls++
	executions.executionID = executionID
	if executions.err != nil {
		return workercontracts.InspectJoinResponseV1{}, executions.err
	}
	if executions.failure {
		return workercontracts.InspectJoinResponseV1{
			Kind: workercontracts.ProbeResponseFailed,
			Failure: &workercontracts.InspectJoinFailureResponseV1{
				Reason: workercontracts.InspectJoinInternal,
			},
		}, nil
	}
	state := executions.state
	if state == "" {
		state = workercontracts.InspectJoinAbsent
	}
	return workercontracts.InspectJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.InspectJoinSuccessResponseV1{
			State: state,
		},
	}, nil
}
