package workerserver

import (
	"fmt"
	"net/http"
)

func NewRouter(
	probe *Handler,
	blurayIdentify *BlurayIdentifyHandler,
	blurayRemux *BlurayRemuxHandler,
	blurayPublish *BlurayPublishHandler,
	stageJoin *StageJoinHandler,
	publish *PublishHandler,
	discard *DiscardHandler,
	inspectJoin *InspectJoinHandler,
) (http.Handler, error) {
	if probe == nil {
		return nil, fmt.Errorf("probe handler is required")
	}
	if blurayIdentify == nil {
		return nil, fmt.Errorf("Blu-ray identification handler is required")
	}
	if blurayRemux == nil {
		return nil, fmt.Errorf("Blu-ray remux handler is required")
	}
	if blurayPublish == nil {
		return nil, fmt.Errorf("Blu-ray publish handler is required")
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
	if inspectJoin == nil {
		return nil, fmt.Errorf("join inspection handler is required")
	}
	router := http.NewServeMux()
	router.Handle(probePath, probe)
	router.Handle(blurayIdentifyPath, blurayIdentify)
	router.Handle(blurayRemuxPath, blurayRemux)
	router.Handle(blurayPublishPath, blurayPublish)
	router.Handle(stageJoinPath, stageJoin)
	router.Handle(publishPath, publish)
	router.Handle(discardPath, discard)
	router.Handle(inspectJoinPath, inspectJoin)
	return router, nil
}
