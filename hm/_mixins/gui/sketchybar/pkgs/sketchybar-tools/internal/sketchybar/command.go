package sketchybar

import (
	"fmt"
	"os/exec"
)

type Runner interface {
	Run(arguments ...string) error
}

type Command struct {
	Executable string
}

func (bar Command) Run(arguments ...string) error {
	if err := exec.Command(bar.Executable, arguments...).Run(); err != nil {
		return fmt.Errorf("update SketchyBar: %w", err)
	}
	return nil
}
