package servarr

import (
	"context"
	"fmt"

	"golift.io/starr"
)

type QueueDeleteFunc func(context.Context, int64, *starr.QueueDeleteOpts) error

func RemoveQueueTracking(
	ctx context.Context,
	service string,
	queueID int64,
	remove QueueDeleteFunc,
) error {
	if service == "" || queueID <= 0 || remove == nil {
		return fmt.Errorf("Servarr queue removal is invalid")
	}
	err := remove(ctx, queueID, &starr.QueueDeleteOpts{
		RemoveFromClient: starr.False(),
		BlockList:        false,
		SkipRedownload:   true,
		ChangeCategory:   false,
	})
	if err != nil {
		return NormalizeRequestError(service, "remove completed queue tracking", err)
	}
	return nil
}
