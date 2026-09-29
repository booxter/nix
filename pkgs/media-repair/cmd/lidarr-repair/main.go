package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	lidarrsource "github.com/booxter/nix-config/media-repair/internal/lidarr"
	"github.com/booxter/nix-config/media-repair/internal/lidarrrepair"
	"github.com/booxter/nix-config/media-repair/internal/lidarrreview"
	"github.com/booxter/nix-config/media-repair/internal/mediaroot"
	"github.com/booxter/nix-config/media-repair/internal/plannerclient"
	planningrunner "github.com/booxter/nix-config/media-repair/internal/planning"
	"github.com/booxter/nix-config/media-repair/internal/queueaction"
	"github.com/booxter/nix-config/media-repair/internal/queuefinalize"
	"github.com/booxter/nix-config/media-repair/internal/reconsideration"
	"github.com/booxter/nix-config/media-repair/internal/review"
	"github.com/booxter/nix-config/media-repair/internal/servarr"
	"github.com/booxter/nix-config/media-repair/internal/workerclient"
	"github.com/booxter/nix-config/media-repair/lidarrcontracts"
)

const (
	defaultRequestTimeout = 30 * time.Second
	defaultStageTimeout   = 30 * time.Minute
	defaultPlannerTimeout = 21 * time.Minute
	defaultRetryInitial   = 5 * time.Minute
	defaultRetryMaximum   = 6 * time.Hour
)

type config struct {
	LidarrURL          string
	APIKeyFile         string
	StateDir           string
	WorkerSocket       string
	WorkerRoots        map[string]string
	PlannerSocket      string
	RequestLimit       time.Duration
	StageLimit         time.Duration
	PlannerLimit       time.Duration
	Apply              bool
	AllowedActions     map[lidarrcontracts.DecisionAction]bool
	AllowedSources     map[lidarrrepair.SourceKind]bool
	KillSwitchFile     string
	PollInterval       time.Duration
	FinalizeStale      bool
	ReviewDir          string
	ReconsiderationDir string
	QueueActionDir     string
}

type report struct {
	Observed      int
	Candidates    int
	Planned       int
	Cached        int
	Deferred      int
	NoRepair      int
	Actions       int
	Imported      int
	Failed        int
	Finalized     int
	Reconciled    int
	ApplyDisabled bool
}

type observeFunc func(context.Context, config) (report, error)

type application struct {
	observe observeFunc
}

func run(ctx context.Context, arguments []string, stdout, stderr io.Writer) error {
	return application{observe: runController}.run(ctx, arguments, stdout, stderr)
}

type allowedActionsValue struct {
	actions map[lidarrcontracts.DecisionAction]bool
}

type allowedSourcesValue struct {
	sources map[lidarrrepair.SourceKind]bool
}

func (value *allowedSourcesValue) String() string { return "" }

func (value *allowedSourcesValue) Set(raw string) error {
	source := lidarrrepair.SourceKind(raw)
	if source != lidarrrepair.SourceTarAudio && source != lidarrrepair.SourceRARAudio &&
		source != lidarrrepair.SourceDirectoryAudio {
		return fmt.Errorf("source %q cannot be allowed for automatic Lidarr repair", raw)
	}
	value.sources[source] = true
	return nil
}

func (value *allowedActionsValue) String() string { return "" }

func (value *allowedActionsValue) Set(raw string) error {
	action := lidarrcontracts.DecisionAction(raw)
	if action != lidarrcontracts.ActionImportMissingTracks {
		return fmt.Errorf("action %q cannot be allowed for automatic Lidarr repair", raw)
	}
	value.actions[action] = true
	return nil
}

func (app application) run(
	ctx context.Context,
	arguments []string,
	stdout io.Writer,
	stderr io.Writer,
) error {
	flags := flag.NewFlagSet("lidarr-repair", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		_, _ = fmt.Fprintln(
			stderr,
			"usage: lidarr-repair --lidarr-url URL --lidarr-api-key-file FILE "+
				"--worker-socket PATH --worker-root ID=PATH --planner-socket PATH "+
				"--state-directory DIR [--apply --allow-action ACTION --allow-source SOURCE "+
				"--kill-switch-file FILE]",
		)
	}
	lidarrURL := flags.String("lidarr-url", "", "loopback Lidarr URL")
	apiKeyFile := flags.String("lidarr-api-key-file", "", "Lidarr API-key credential file")
	stateDirectory := flags.String("state-directory", "", "private controller state directory")
	workerSocket := flags.String("worker-socket", "", "media worker Unix socket")
	workerRoots := mediaroot.NewMappings()
	flags.Var(workerRoots, "worker-root", "worker media root as ID=PATH; repeatable")
	plannerSocket := flags.String("planner-socket", "", "repair planner Unix socket")
	timeout := flags.Duration("request-timeout", defaultRequestTimeout, "Lidarr request timeout")
	stageTimeout := flags.Duration("worker-stage-timeout", defaultStageTimeout, "worker stage timeout")
	plannerTimeout := flags.Duration("planner-timeout", defaultPlannerTimeout, "planner request timeout")
	apply := flags.Bool("apply", false, "acknowledge that one permitted repair may be applied")
	allowed := allowedActionsValue{actions: make(map[lidarrcontracts.DecisionAction]bool)}
	flags.Var(&allowed, "allow-action", "repair action to permit; repeatable")
	allowedSources := allowedSourcesValue{sources: make(map[lidarrrepair.SourceKind]bool)}
	flags.Var(&allowedSources, "allow-source", "repair source to permit; repeatable")
	killSwitchFile := flags.String(
		"kill-switch-file", "", "existing filesystem entry disables repair application",
	)
	pollInterval := flags.Duration(
		"poll-interval", 2*time.Second, "Lidarr import confirmation poll interval",
	)
	finalizeStale := flags.Bool(
		"finalize-stale-queue", false,
		"remove tracking for completed warnings whose monitored release is complete",
	)
	reviewDirectory := flags.String(
		"review-directory", "", "optional sanitized review snapshot directory",
	)
	reconsiderationDirectory := flags.String(
		"reconsideration-directory", "", "optional reconsideration request directory",
	)
	queueActionDirectory := flags.String(
		"queue-action-directory", "", "optional operator queue action directory",
	)
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		flags.Usage()
		return fmt.Errorf("unexpected positional arguments")
	}
	configuration := config{
		LidarrURL: *lidarrURL, APIKeyFile: *apiKeyFile,
		StateDir: *stateDirectory, WorkerSocket: *workerSocket,
		WorkerRoots: workerRoots.Paths(), PlannerSocket: *plannerSocket,
		RequestLimit: *timeout, StageLimit: *stageTimeout, PlannerLimit: *plannerTimeout,
		Apply: *apply, AllowedActions: allowed.actions, AllowedSources: allowedSources.sources,
		KillSwitchFile:     *killSwitchFile,
		PollInterval:       *pollInterval,
		FinalizeStale:      *finalizeStale,
		ReviewDir:          *reviewDirectory,
		ReconsiderationDir: *reconsiderationDirectory,
		QueueActionDir:     *queueActionDirectory,
	}
	if err := validateConfig(configuration); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if app.observe == nil {
		return fmt.Errorf("queue observer is not configured")
	}
	result, err := app.observe(ctx, configuration)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(
		stdout,
		"observed=%d candidates=%d planned=%d cached=%d deferred=%d no_repair=%d "+
			"actions=%d imported=%d failed=%d finalized=%d reconciled=%d apply_disabled=%t\n",
		result.Observed, result.Candidates, result.Planned, result.Cached, result.Deferred,
		result.NoRepair,
		result.Actions, result.Imported, result.Failed, result.Finalized, result.Reconciled,
		result.ApplyDisabled,
	)
	return err
}

func validateConfig(configuration config) error {
	if err := servarr.ValidateLoopbackHTTP("Lidarr", configuration.LidarrURL); err != nil {
		return err
	}
	if !filepath.IsAbs(configuration.APIKeyFile) ||
		filepath.Clean(configuration.APIKeyFile) != configuration.APIKeyFile {
		return fmt.Errorf("Lidarr API-key file must be an absolute clean path")
	}
	if !filepath.IsAbs(configuration.StateDir) ||
		filepath.Clean(configuration.StateDir) != configuration.StateDir ||
		filepath.Dir(configuration.StateDir) == configuration.StateDir {
		return fmt.Errorf("state directory must be an absolute clean path")
	}
	if configuration.ReviewDir != "" && (!filepath.IsAbs(configuration.ReviewDir) ||
		filepath.Clean(configuration.ReviewDir) != configuration.ReviewDir ||
		filepath.Dir(configuration.ReviewDir) == configuration.ReviewDir) {
		return fmt.Errorf("review directory must be an absolute clean path")
	}
	if configuration.ReconsiderationDir != "" &&
		(!filepath.IsAbs(configuration.ReconsiderationDir) ||
			filepath.Clean(configuration.ReconsiderationDir) != configuration.ReconsiderationDir ||
			filepath.Dir(configuration.ReconsiderationDir) == configuration.ReconsiderationDir) {
		return fmt.Errorf("reconsideration directory must be an absolute clean path")
	}
	if configuration.QueueActionDir != "" &&
		(!filepath.IsAbs(configuration.QueueActionDir) ||
			filepath.Clean(configuration.QueueActionDir) != configuration.QueueActionDir ||
			filepath.Dir(configuration.QueueActionDir) == configuration.QueueActionDir) {
		return fmt.Errorf("queue action directory must be an absolute clean path")
	}
	for name, path := range map[string]string{
		"worker socket":  configuration.WorkerSocket,
		"planner socket": configuration.PlannerSocket,
	} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path {
			return fmt.Errorf("%s must be an absolute clean path", name)
		}
	}
	if len(configuration.WorkerRoots) == 0 {
		return fmt.Errorf("at least one worker root is required")
	}
	if configuration.RequestLimit <= 0 || configuration.StageLimit <= 0 ||
		configuration.PlannerLimit <= 0 || configuration.PollInterval <= 0 {
		return fmt.Errorf("request timeouts must be positive")
	}
	if configuration.Apply {
		if len(configuration.AllowedActions) == 0 {
			return fmt.Errorf("at least one --allow-action is required in apply mode")
		}
		if len(configuration.AllowedSources) == 0 {
			return fmt.Errorf("at least one --allow-source is required in apply mode")
		}
		if !filepath.IsAbs(configuration.KillSwitchFile) ||
			filepath.Clean(configuration.KillSwitchFile) != configuration.KillSwitchFile {
			return fmt.Errorf("kill-switch file must be an absolute clean path")
		}
	} else if len(configuration.AllowedActions) != 0 || len(configuration.AllowedSources) != 0 ||
		configuration.KillSwitchFile != "" || configuration.FinalizeStale {
		return fmt.Errorf("apply guards require --apply")
	}
	return nil
}

func runController(ctx context.Context, configuration config) (report, error) {
	apiKey, err := servarr.ReadAPIKey("Lidarr", configuration.APIKeyFile)
	if err != nil {
		return report{}, err
	}
	transport, err := servarr.DirectHTTPTransport()
	if err != nil {
		return report{}, err
	}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{
		Transport: transport,
		Timeout:   configuration.RequestLimit,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	client, err := lidarrsource.New(configuration.LidarrURL, apiKey, httpClient)
	if err != nil {
		return report{}, fmt.Errorf("configure Lidarr client: %w", err)
	}
	worker, err := workerclient.New(
		configuration.WorkerSocket, configuration.WorkerRoots,
		configuration.RequestLimit, configuration.StageLimit,
	)
	if err != nil {
		return report{}, fmt.Errorf("configure media worker client: %w", err)
	}
	defer worker.Close()
	planner, err := plannerclient.New(configuration.PlannerSocket, configuration.PlannerLimit)
	if err != nil {
		return report{}, fmt.Errorf("configure repair planner client: %w", err)
	}
	defer planner.Close()
	store, err := lidarrrepair.NewStore(configuration.StateDir)
	if err != nil {
		return report{}, err
	}
	runner, err := lidarrrepair.NewRunner(client, worker, planner, store)
	if err != nil {
		return report{}, err
	}
	if configuration.ReconsiderationDir != "" {
		requests, requestErr := reconsideration.NewStore(
			configuration.ReconsiderationDir, reconsideration.ServiceLidarr,
		)
		if requestErr != nil {
			return report{}, fmt.Errorf("configure reconsideration inbox: %w", requestErr)
		}
		results, resultErr := reconsideration.NewResultStore(
			filepath.Join(configuration.StateDir, "reconsiderations"),
			validateLidarrRevision,
		)
		if resultErr != nil {
			return report{}, fmt.Errorf("configure reconsideration results: %w", resultErr)
		}
		processor, processorErr := reconsideration.NewProcessor(
			results,
			func(
				requestContext context.Context,
				request reconsideration.Request,
				priorData json.RawMessage,
			) (json.RawMessage, error) {
				prior, decodeErr := lidarrcontracts.DecodeDecision(priorData)
				if decodeErr != nil {
					return nil, decodeErr
				}
				repairCase, readErr := store.GetRepairCase(request.CaseID)
				if readErr != nil {
					return nil, readErr
				}
				decision, planErr := planner.ReconsiderLidarr(
					requestContext, repairCase, prior, request,
				)
				if planErr != nil {
					return nil, planErr
				}
				if validateErr := lidarrrepair.ValidateDecision(repairCase, decision); validateErr != nil {
					return nil, &planningrunner.InvalidResultError{Err: validateErr}
				}
				return lidarrcontracts.EncodeDecision(decision)
			},
			time.Now,
			planningrunner.ClassifyFailure,
			planningrunner.Backoff{Initial: defaultRetryInitial, Maximum: defaultRetryMaximum},
		)
		if processorErr != nil {
			return report{}, fmt.Errorf("configure reconsideration processor: %w", processorErr)
		}
		if enableErr := runner.EnableReconsideration(requests, processor); enableErr != nil {
			return report{}, enableErr
		}
	}
	result, err := runner.Run(ctx)
	removals, removalErr := processLidarrQueueActions(ctx, configuration, client)
	if len(removals) != 0 {
		pending := make(map[string]struct{}, len(removals))
		for _, removal := range removals {
			pending[removal.Request.CaseID] = struct{}{}
		}
		filtered := result.PlannedCases[:0]
		for _, planned := range result.PlannedCases {
			caseID, caseErr := lidarrRecordCaseID(planned)
			if caseErr != nil {
				return report{}, caseErr
			}
			if _, remove := pending[caseID]; !remove {
				filtered = append(filtered, planned)
			}
		}
		result.PlannedCases = filtered
	}
	controllerReport := report{
		Observed: result.Observed, Candidates: result.Candidates,
		Planned: result.Planned, Cached: result.Cached, Deferred: result.Deferred,
		NoRepair: result.NoRepair,
	}
	publishErr := publishLidarrReviewWithRemovals(
		configuration.ReviewDir, result, removals, time.Now().UTC(),
	)
	if err != nil || removalErr != nil || publishErr != nil || !configuration.Apply {
		return controllerReport, errors.Join(err, removalErr, publishErr)
	}
	disabled, err := applyDisabled(configuration.KillSwitchFile)
	if err != nil {
		return controllerReport, err
	}
	if disabled {
		controllerReport.ApplyDisabled = true
		return controllerReport, nil
	}
	importer, err := lidarrrepair.NewImportExecutor(lidarrrepair.ImportExecutorDependencies{
		Lidarr: client, Store: store, Clock: wallClock{}, Waiter: servarr.Timer{},
		PollInterval: configuration.PollInterval,
	})
	if err != nil {
		return controllerReport, err
	}
	queues, err := client.ReadQueue(ctx)
	if err != nil {
		return controllerReport, fmt.Errorf("refresh Lidarr queue before apply: %w", err)
	}
	queuesByID := make(map[int64]lidarrsource.QueueRecord, len(queues))
	for _, queue := range queues {
		queuesByID[queue.ID] = queue
	}
	for _, planned := range result.PlannedCases {
		queue, found := queuesByID[planned.QueueID]
		if !found {
			continue
		}
		if !configuration.AllowedSources[planned.SourceKind] {
			continue
		}
		decision, decodeErr := lidarrcontracts.DecodeDecision(planned.Decision)
		if decodeErr != nil {
			return controllerReport, decodeErr
		}
		if !configuration.AllowedActions[decision.Kind] {
			continue
		}
		current, buildErr := runner.BuildCurrentEvidence(ctx, queue)
		if buildErr != nil {
			return controllerReport, fmt.Errorf("queue %d: refresh repair evidence: %w", queue.ID, buildErr)
		}
		authorized, accepted, authorizeErr := lidarrrepair.AuthorizeImport(planned, current)
		if authorizeErr != nil {
			return controllerReport, fmt.Errorf("queue %d: authorize repair: %w", queue.ID, authorizeErr)
		}
		if !accepted {
			continue
		}
		execution, executeErr := importer.Execute(ctx, authorized)
		controllerReport.Actions++
		switch execution.State {
		case lidarrrepair.Imported:
			controllerReport.Imported++
		case lidarrrepair.ImportFailed:
			controllerReport.Failed++
		}
		return controllerReport, executeErr
	}
	if configuration.FinalizeStale {
		finalization, finalizeErr := finalizeLidarrQueue(ctx, configuration, client)
		controllerReport.Finalized = finalization.Finalized
		controllerReport.Reconciled = finalization.Reconciled
		if finalizeErr != nil {
			return controllerReport, finalizeErr
		}
	}
	return controllerReport, nil
}

func validateLidarrRevision(data json.RawMessage) (string, json.RawMessage, error) {
	decision, err := lidarrcontracts.DecodeDecision(data)
	if err != nil {
		return "", nil, err
	}
	canonical, err := lidarrcontracts.EncodeDecision(decision)
	return decision.CaseID(), canonical, err
}

func publishLidarrReview(
	directory string,
	report lidarrrepair.Report,
	generatedAt time.Time,
) error {
	return publishLidarrReviewWithRemovals(directory, report, nil, generatedAt)
}

func publishLidarrReviewWithRemovals(
	directory string,
	report lidarrrepair.Report,
	removals []queueaction.Processed,
	generatedAt time.Time,
) error {
	if directory == "" {
		return nil
	}
	snapshot, err := lidarrreview.Snapshot(report, generatedAt)
	if err != nil {
		return fmt.Errorf("build Lidarr review snapshot: %w", err)
	}
	if err := review.ApplyQueueRemovals(&snapshot, removals); err != nil {
		return fmt.Errorf("add Lidarr queue removals to review snapshot: %w", err)
	}
	store, err := review.NewStore(directory)
	if err != nil {
		return fmt.Errorf("configure Lidarr review store: %w", err)
	}
	if err := store.Publish(snapshot); err != nil {
		return fmt.Errorf("publish Lidarr review snapshot: %w", err)
	}
	return nil
}

func processLidarrQueueActions(
	ctx context.Context,
	configuration config,
	client *lidarrsource.Client,
) ([]queueaction.Processed, error) {
	if configuration.QueueActionDir == "" {
		return nil, nil
	}
	requests, err := queueaction.NewStore(
		configuration.QueueActionDir, queueaction.ServiceLidarr,
	)
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr queue action inbox: %w", err)
	}
	results, err := queueaction.NewResultStore(
		filepath.Join(configuration.StateDir, "queue-action-results"),
	)
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr queue action results: %w", err)
	}
	finalizer, err := queuefinalize.New(queuefinalize.Dependencies{
		Service: "Lidarr", StateDirectory: configuration.StateDir,
		ReadQueue: func(ctx context.Context) ([]queuefinalize.Entry, error) {
			records, readErr := client.ReadQueue(ctx)
			if readErr != nil {
				return nil, readErr
			}
			entries := make([]queuefinalize.Entry, len(records))
			for index, record := range records {
				entries[index] = lidarrsource.FinalizationEntry(record)
			}
			return entries, nil
		},
		Remove: client.FinalizeQueue, Clock: wallClock{},
	})
	if err != nil {
		return nil, fmt.Errorf("configure Lidarr queue action finalizer: %w", err)
	}
	processor, err := queueaction.NewProcessor(results, finalizer, time.Now)
	if err != nil {
		return nil, err
	}
	return queueaction.ProcessLatest(ctx, requests, processor)
}

func lidarrRecordCaseID(record lidarrrepair.Record) (string, error) {
	repairCase, err := lidarrcontracts.DecodeCase(record.Case)
	if err != nil {
		return "", err
	}
	return repairCase.CaseID, nil
}

func finalizeLidarrQueue(
	ctx context.Context,
	configuration config,
	client *lidarrsource.Client,
) (queuefinalize.Report, error) {
	candidates, err := lidarrsource.FinalizationCandidates(ctx, client)
	if err != nil {
		return queuefinalize.Report{}, err
	}
	finalizer, err := queuefinalize.New(queuefinalize.Dependencies{
		Service: "Lidarr", StateDirectory: configuration.StateDir,
		ReadQueue: func(ctx context.Context) ([]queuefinalize.Entry, error) {
			records, err := client.ReadQueue(ctx)
			if err != nil {
				return nil, err
			}
			entries := make([]queuefinalize.Entry, len(records))
			for index, record := range records {
				entries[index] = lidarrsource.FinalizationEntry(record)
			}
			return entries, nil
		},
		Remove: client.FinalizeQueue,
		Clock:  wallClock{},
	})
	if err != nil {
		return queuefinalize.Report{}, fmt.Errorf("configure Lidarr queue finalizer: %w", err)
	}
	return finalizer.Run(ctx, candidates, 1)
}

type wallClock struct{}

func (wallClock) Now() time.Time { return time.Now() }

func applyDisabled(path string) (bool, error) {
	_, err := os.Lstat(path)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return false, fmt.Errorf("inspect Lidarr repair kill switch: %w", err)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
