package workerserver

import (
	"fmt"
	"net/http"
)

type Operation interface {
	http.Handler
	OperationPath() string
}

func NewRouter(operations ...Operation) (http.Handler, error) {
	if len(operations) == 0 {
		return nil, fmt.Errorf("at least one worker operation is required")
	}
	router := http.NewServeMux()
	paths := make(map[string]struct{}, len(operations))
	for index, operation := range operations {
		path := operation.OperationPath()
		if path == "" {
			return nil, fmt.Errorf("worker operation %d is not configured", index)
		}
		if _, duplicate := paths[path]; duplicate {
			return nil, fmt.Errorf("multiple worker operations use path %q", path)
		}
		paths[path] = struct{}{}
		router.Handle(path, operation)
	}
	return router, nil
}
