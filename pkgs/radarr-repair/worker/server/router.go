package workerserver

import (
	"fmt"
	"net/http"
)

func NewRouter(
	probe *Handler,
	stageJoin *StageJoinHandler,
) (http.Handler, error) {
	if probe == nil {
		return nil, fmt.Errorf("probe handler is required")
	}
	if stageJoin == nil {
		return nil, fmt.Errorf("stage join handler is required")
	}
	router := http.NewServeMux()
	router.Handle(probePath, probe)
	router.Handle(stageJoinPath, stageJoin)
	return router, nil
}
