package repoacl

import (
	"fmt"
	"os/exec"
)

const batchSize = 128

type Setfacl struct {
	Executable string
}

func (setfacl Setfacl) GrantAccess(user string, paths []string) error {
	return setfacl.apply([]string{"-m", fmt.Sprintf("u:%s:rwX,m::rwX", user)}, paths)
}

func (setfacl Setfacl) GrantDefault(user string, directories []string) error {
	return setfacl.apply([]string{"-d", "-m", fmt.Sprintf("u:%s:rwx,m::rwx", user)}, directories)
}

func (setfacl Setfacl) apply(options, paths []string) error {
	for start := 0; start < len(paths); start += batchSize {
		end := min(start+batchSize, len(paths))
		arguments := append(append([]string{}, options...), paths[start:end]...)
		command := exec.Command(setfacl.Executable, arguments...)
		if output, err := command.CombinedOutput(); err != nil {
			return fmt.Errorf("set repository ACL: %w: %s", err, output)
		}
	}
	return nil
}
