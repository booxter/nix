package controller

import "time"

type Clock interface {
	Now() time.Time
}
