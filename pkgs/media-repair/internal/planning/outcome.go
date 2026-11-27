package planning

type Outcome string

const (
	Repair      Outcome = "repair"
	Decline     Outcome = "decline"
	AskOperator Outcome = "ask_operator"
)

// Save the question with the decision so an operator answers the choices
// offered for that case, including after a daemon restart.
type Result struct {
	Outcome  Outcome
	Question *Question `json:",omitempty"`
}

type QuestionKind string

const (
	ChooseFile      QuestionKind = "file"
	ChooseRelease   QuestionKind = "release"
	ProvideGuidance QuestionKind = "guidance"
	AcceptRuntime   QuestionKind = "runtime"
	Retry           QuestionKind = "retry"
)

type Question struct {
	Kind            QuestionKind `json:"kind"`
	Title           string       `json:"title"`
	Text            string       `json:"text"`
	Hint            string       `json:"hint,omitempty"`
	Button          string       `json:"button"`
	Choices         []Choice     `json:"choices,omitempty"`
	Context         []string     `json:"context,omitempty"`
	AllowRuntime    bool         `json:"allowRuntime,omitempty"`
	RequireGuidance bool         `json:"requireGuidance,omitempty"`
}

type Choice struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

func RequestGuidance(title, text string) *Question {
	return &Question{Kind: ProvideGuidance, Title: title, Text: text, Button: "Send instructions", RequireGuidance: true}
}

func RetryPlanning() *Question {
	return &Question{Kind: Retry, Title: "Retry planning", Text: "Try planning again?", Button: "Retry planning"}
}

// Both planners return no_repair for a decline, a question, or exhausted
// planning attempts. Only the latter two need an operator answer.
func NoRepair(reason string, question *Question) Result {
	if reason == "planner_failed" {
		question = RetryPlanning()
	}
	if question != nil {
		return Result{Outcome: AskOperator, Question: question}
	}
	return Result{Outcome: Decline}
}
