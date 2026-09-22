package servarr

import "fmt"

type CommandStatus string

const (
	CommandQueued    CommandStatus = "queued"
	CommandStarted   CommandStatus = "started"
	CommandCompleted CommandStatus = "completed"
	CommandFailed    CommandStatus = "failed"
	CommandAborted   CommandStatus = "aborted"
	CommandCancelled CommandStatus = "cancelled"
	CommandOrphaned  CommandStatus = "orphaned"
)

type CommandResult string

const (
	CommandResultUnknown      CommandResult = "unknown"
	CommandResultSuccessful   CommandResult = "successful"
	CommandResultUnsuccessful CommandResult = "unsuccessful"
)

type Command struct {
	ID        int64
	Name      string
	Message   string
	Exception string
	Status    CommandStatus
	Result    CommandResult
}

type ImportCommandDisposition uint8

const (
	ImportCommandPending ImportCommandDisposition = iota + 1
	ImportCommandCompleted
	ImportCommandFailed
)

// ClassifyImportCommand distinguishes active, completed, and definitely failed
// commands. History remains the authority for whether each file was imported.
// Some Servarr applications do not expose a command result; callers choose
// whether a completed command must include one.
func ClassifyImportCommand(
	service string,
	command Command,
	requireCompletionResult bool,
) (ImportCommandDisposition, error) {
	switch command.Status {
	case CommandQueued, CommandStarted:
		if command.Result != "" && command.Result != CommandResultUnknown {
			return 0, fmt.Errorf(
				"active %s import command has unexpected result %q",
				service,
				command.Result,
			)
		}
		return ImportCommandPending, nil
	case CommandCompleted:
		switch command.Result {
		case CommandResultSuccessful:
			return ImportCommandCompleted, nil
		case CommandResultUnsuccessful:
			return ImportCommandFailed, nil
		case "":
			if !requireCompletionResult {
				return ImportCommandCompleted, nil
			}
		}
		return 0, fmt.Errorf(
			"completed %s import command has unexpected result %q",
			service,
			command.Result,
		)
	case CommandFailed, CommandAborted, CommandCancelled, CommandOrphaned:
		return ImportCommandFailed, nil
	default:
		return 0, fmt.Errorf(
			"%s import command has unknown status %q",
			service,
			command.Status,
		)
	}
}
