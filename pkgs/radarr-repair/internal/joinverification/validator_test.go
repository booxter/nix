package joinverification

import (
	"testing"

	"github.com/booxter/nix-config/radarr-repair/internal/controller"
	"github.com/booxter/nix-config/radarr-repair/internal/decisionpolicy"
	workercontracts "github.com/booxter/nix-config/radarr-repair/worker/contracts"
	"github.com/booxter/nix-config/radarr-repair/worker/mediaevidence"
)

const (
	testCaseID              = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
	testArtifactFingerprint = "sha256:4444444444444444444444444444444444444444444444444444444444444444"
)

func TestValidateStagedJoinAuthorizesVerifiedArtifact(t *testing.T) {
	t.Parallel()

	authorized, request, response := validStage()
	validation := ValidateStagedJoin(authorized, request, response)
	if !validation.Accepted() || validation.Publish == nil || validation.Discard != nil {
		t.Fatalf("validation = %#v", validation)
	}
	if validation.Publish.ExecutionID != request.ExecutionID ||
		validation.Publish.CaseID != authorized.CaseID ||
		validation.Publish.CapabilityID != authorized.CapabilityID ||
		validation.Publish.ArtifactID != response.Success.ArtifactID ||
		validation.Publish.ArtifactFingerprint != testArtifactFingerprint ||
		validation.Publish.SizeBytes != response.Success.SizeBytes {
		t.Fatalf("publication authorization = %#v", validation.Publish)
	}
}

func TestValidateStagedJoinAcceptsMP4Output(t *testing.T) {
	t.Parallel()

	authorized, request, response := validStage()
	authorized.OutputContainer = controller.OutputContainerMP4
	request.OutputContainer = workercontracts.OutputContainerMP4
	evidence := joinedEvidence()
	evidence.Format.Names = []string{"mov", "mp4", "m4a", "3gp", "3g2", "mj2"}
	response.Success.Evidence = mediaevidence.FromProbe(evidence)
	if validation := ValidateStagedJoin(authorized, request, response); !validation.Accepted() {
		t.Fatalf("validation = %#v", validation)
	}
}

func TestValidateStagedJoinRequiresAuthorizedRequest(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*workercontracts.StageJoinRequestV1)
	}{
		{
			name: "case",
			mutate: func(request *workercontracts.StageJoinRequestV1) {
				request.CaseID = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
			},
		},
		{
			name: "capability",
			mutate: func(request *workercontracts.StageJoinRequestV1) {
				request.CapabilityID = "capability:other"
			},
		},
		{
			name: "duration",
			mutate: func(request *workercontracts.StageJoinRequestV1) {
				request.ExpectedDurationMS++
			},
		},
		{
			name: "part order",
			mutate: func(request *workercontracts.StageJoinRequestV1) {
				request.Parts[0], request.Parts[1] = request.Parts[1], request.Parts[0]
			},
		},
		{
			name: "fingerprint",
			mutate: func(request *workercontracts.StageJoinRequestV1) {
				request.Parts[0].ExpectedFingerprint =
					"sha256:3333333333333333333333333333333333333333333333333333333333333333"
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			authorized, request, response := validStage()
			test.mutate(&request)
			validation := ValidateStagedJoin(authorized, request, response)
			assertRejectedFor(t, validation, StageRequestNotAuthorized, true)
		})
	}
}

func TestValidateStagedJoinRequiresCorrelatedResponse(t *testing.T) {
	t.Parallel()

	authorized, request, response := validStage()
	response.Success.RequestID = "request:other"
	validation := ValidateStagedJoin(authorized, request, response)
	assertRejectedFor(t, validation, StageResponseNotCorrelated, true)
}

func TestValidateStagedJoinRejectsWorkerFailureWithoutArtifactAuthority(t *testing.T) {
	t.Parallel()

	authorized, request, _ := validStage()
	response := workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseFailed,
		Failure: &workercontracts.StageJoinFailureResponseV1{
			Operation:     workercontracts.StageJoinV1,
			Reason:        workercontracts.StageJoinJoinError,
			RequestID:     request.RequestID,
			SchemaVersion: workercontracts.RadarrRepairWorkerV1,
			Status:        workercontracts.Failed,
		},
	}
	validation := ValidateStagedJoin(authorized, request, response)
	assertRejectedFor(t, validation, StageFailed, false)
}

func TestValidateStagedJoinRejectsInvalidResponseIdentity(t *testing.T) {
	t.Parallel()

	authorized, request, response := validStage()
	response.Success.ArtifactID = ""
	validation := ValidateStagedJoin(authorized, request, response)
	assertRejectedFor(t, validation, InvalidStageResponse, false)
}

func TestValidateStagedJoinRejectsInvalidMediaEvidence(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		reason RejectionReason
		mutate func(*controller.ProbeEvidence)
	}{
		{
			name:   "reported size",
			reason: ArtifactSizeMismatch,
			mutate: func(evidence *controller.ProbeEvidence) {
				evidence.Format.SizeBytes = value[int64](189)
			},
		},
		{
			name:   "omitted duration",
			reason: DurationOutsideTolerance,
			mutate: func(evidence *controller.ProbeEvidence) {
				setDuration(evidence, 18_999)
			},
		},
		{
			name:   "excess duration",
			reason: DurationOutsideTolerance,
			mutate: func(evidence *controller.ProbeEvidence) {
				setDuration(evidence, 21_001)
			},
		},
		{
			name:   "missing duration",
			reason: DurationUnavailable,
			mutate: func(evidence *controller.ProbeEvidence) {
				evidence.Format.DurationMS = nil
				for position := range evidence.Streams {
					evidence.Streams[position].DurationMS = nil
				}
			},
		},
		{
			name:   "container",
			reason: OutputContainerMismatch,
			mutate: func(evidence *controller.ProbeEvidence) {
				evidence.Format.Names = []string{"mov", "mp4"}
			},
		},
		{
			name:   "changed stream",
			reason: StreamLayoutMismatch,
			mutate: func(evidence *controller.ProbeEvidence) {
				evidence.Streams[1].Channels = value[int64](6)
			},
		},
		{
			name:   "reordered streams",
			reason: StreamLayoutMismatch,
			mutate: func(evidence *controller.ProbeEvidence) {
				evidence.Streams[0].Index = 1
				evidence.Streams[1].Index = 0
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			authorized, request, response := validStage()
			evidence := joinedEvidence()
			test.mutate(&evidence)
			response.Success.Evidence = mediaevidence.FromProbe(evidence)
			validation := ValidateStagedJoin(authorized, request, response)
			assertRejectedFor(t, validation, test.reason, true)
		})
	}
}

func TestValidateStagedJoinAcceptsDurationToleranceBoundaries(t *testing.T) {
	t.Parallel()

	for _, duration := range []int64{19_000, 21_000} {
		authorized, request, response := validStage()
		evidence := joinedEvidence()
		setDuration(&evidence, duration)
		response.Success.Evidence = mediaevidence.FromProbe(evidence)
		if validation := ValidateStagedJoin(authorized, request, response); !validation.Accepted() {
			t.Fatalf("duration %d validation = %#v", duration, validation)
		}
	}
}

func validStage() (
	decisionpolicy.AuthorizedJoin,
	workercontracts.StageJoinRequestV1,
	workercontracts.StageJoinResponseV1,
) {
	firstFingerprint := controller.FileFingerprint{
		Device: 1, Inode: 2, SizeBytes: 100, MTimeNS: 3,
	}
	secondFingerprint := controller.FileFingerprint{
		Device: 1, Inode: 4, SizeBytes: 100, MTimeNS: 5,
	}
	authorized := decisionpolicy.AuthorizedJoin{
		CaseID:       testCaseID,
		CapabilityID: "capability:join:01",
		OrderedParts: []decisionpolicy.AuthorizedJoinPart{
			{FileID: "file:first", Fingerprint: firstFingerprint},
			{FileID: "file:second", Fingerprint: secondFingerprint},
		},
		SourceBytes:         200,
		ExpectedDurationMS:  20_000,
		DurationToleranceMS: 1_000,
		OutputContainer:     controller.OutputContainerMKV,
		ExpectedStreamLayout: controller.StreamLayout{Streams: []controller.StreamLayoutEntry{
			videoLayout(), audioLayout(),
		}},
	}
	request := workercontracts.StageJoinRequestV1{
		CapabilityID:        authorized.CapabilityID,
		CaseID:              authorized.CaseID,
		DurationToleranceMS: authorized.DurationToleranceMS,
		ExecutionID:         "execution:join:01",
		ExpectedDurationMS:  authorized.ExpectedDurationMS,
		ExpectedSourceBytes: authorized.SourceBytes,
		ExpectedStreamCount: int64(len(authorized.ExpectedStreamLayout.Streams)),
		Operation:           workercontracts.StageJoinV1,
		OutputContainer:     workercontracts.OutputContainerMKV,
		Parts: []workercontracts.StageJoinPartV1{
			{
				ExpectedFingerprint: firstFingerprint.Fingerprint(),
				FileID:              "file:first",
				PathComponents:      []string{"Movie", "Movie CD1.mkv"},
			},
			{
				ExpectedFingerprint: secondFingerprint.Fingerprint(),
				FileID:              "file:second",
				PathComponents:      []string{"Movie", "Movie CD2.mkv"},
			},
		},
		RequestID:     "request:join:01",
		RootID:        "root:downloads",
		SchemaVersion: workercontracts.RadarrRepairWorkerV1,
	}
	evidence := joinedEvidence()
	response := workercontracts.StageJoinResponseV1{
		Kind: workercontracts.ProbeResponseSucceeded,
		Success: &workercontracts.StageJoinSuccessResponseV1{
			ArtifactFingerprint: testArtifactFingerprint,
			ArtifactID:          "artifact:join:01",
			Evidence:            mediaevidence.FromProbe(evidence),
			Operation:           workercontracts.StageJoinV1,
			RequestID:           request.RequestID,
			SchemaVersion:       workercontracts.RadarrRepairWorkerV1,
			SizeBytes:           *evidence.Format.SizeBytes,
			Status:              workercontracts.Ok,
		},
	}
	return authorized, request, response
}

func joinedEvidence() controller.ProbeEvidence {
	return controller.ProbeEvidence{
		Format: controller.ProbeFormat{
			Names:        []string{"matroska", "webm"},
			StreamCount:  value[int64](2),
			ProgramCount: value[int64](0),
			StartTimeMS:  value[int64](0),
			DurationMS:   value[int64](20_000),
			SizeBytes:    value[int64](190),
			ProbeScore:   value[int64](100),
			Tags:         []controller.ProbeTag{},
		},
		Streams: []controller.ProbeStream{
			videoStream(0, 20_000),
			audioStream(1, 20_000),
		},
		Programs: []controller.ProbeProgram{},
		Chapters: []controller.ProbeChapter{},
	}
}

func videoLayout() controller.StreamLayoutEntry {
	return controller.StreamLayoutEntry{
		Kind:      controller.ProbeStreamVideo,
		CodecName: "h264",
		Profile:   value("High"),
		TimeBase:  controller.Rational{Numerator: 1, Denominator: 1_000},
		Video: &controller.VideoStreamLayout{
			Width:       1_920,
			Height:      1_080,
			PixelFormat: "yuv420p",
			AverageRate: controller.Rational{Numerator: 24_000, Denominator: 1_001},
		},
	}
}

func audioLayout() controller.StreamLayoutEntry {
	return controller.StreamLayoutEntry{
		Kind:      controller.ProbeStreamAudio,
		CodecName: "aac",
		Profile:   value("LC"),
		TimeBase:  controller.Rational{Numerator: 1, Denominator: 1_000},
		Audio: &controller.AudioStreamLayout{
			SampleFormat:  "fltp",
			SampleRateHz:  48_000,
			Channels:      2,
			ChannelLayout: "stereo",
		},
	}
}

func videoStream(index int64, duration int64) controller.ProbeStream {
	layout := videoLayout()
	return controller.ProbeStream{
		Index:       index,
		Kind:        value(layout.Kind),
		CodecName:   value(layout.CodecName),
		Profile:     value(*layout.Profile),
		TimeBase:    value(layout.TimeBase),
		Width:       value(layout.Video.Width),
		Height:      value(layout.Video.Height),
		PixelFormat: value(layout.Video.PixelFormat),
		AverageRate: value(layout.Video.AverageRate),
		DurationMS:  value(duration),
		Tags:        []controller.ProbeTag{},
	}
}

func audioStream(index int64, duration int64) controller.ProbeStream {
	layout := audioLayout()
	return controller.ProbeStream{
		Index:         index,
		Kind:          value(layout.Kind),
		CodecName:     value(layout.CodecName),
		Profile:       value(*layout.Profile),
		TimeBase:      value(layout.TimeBase),
		SampleFormat:  value(layout.Audio.SampleFormat),
		SampleRateHz:  value(layout.Audio.SampleRateHz),
		Channels:      value(layout.Audio.Channels),
		ChannelLayout: value(layout.Audio.ChannelLayout),
		DurationMS:    value(duration),
		Tags:          []controller.ProbeTag{},
	}
}

func setDuration(evidence *controller.ProbeEvidence, duration int64) {
	evidence.Format.DurationMS = value(duration)
	for position := range evidence.Streams {
		evidence.Streams[position].DurationMS = value(duration)
	}
}

func assertRejectedFor(
	t *testing.T,
	validation Validation,
	reason RejectionReason,
	discard bool,
) {
	t.Helper()
	if validation.Accepted() || validation.Publish != nil ||
		(validation.Discard != nil) != discard || !hasReason(validation, reason) {
		t.Fatalf("validation = %#v", validation)
	}
}

func hasReason(validation Validation, reason RejectionReason) bool {
	for _, rejection := range validation.Rejections {
		if rejection.Reason == reason {
			return true
		}
	}
	return false
}

func value[T any](input T) *T {
	return &input
}
