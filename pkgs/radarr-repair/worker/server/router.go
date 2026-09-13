package workerserver

import (
	"fmt"
	"net/http"
)

func NewRouter(
	probe *Handler,
	stageJoin *StageJoinHandler,
	publish *PublishHandler,
	discard *DiscardHandler,
) (http.Handler, error) {
	if probe == nil {
		return nil, fmt.Errorf("probe handler is required")
	}
	if stageJoin == nil {
		return nil, fmt.Errorf("stage join handler is required")
	}
	if publish == nil {
		return nil, fmt.Errorf("join publish handler is required")
	}
	if discard == nil {
		return nil, fmt.Errorf("join discard handler is required")
	}
	router := http.NewServeMux()
	router.Handle(probePath, probe)
	router.Handle(stageJoinPath, stageJoin)
	router.Handle(publishPath, publish)
	router.Handle(discardPath, discard)
	return router, nil
}
