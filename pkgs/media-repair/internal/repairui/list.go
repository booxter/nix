package repairui

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	"github.com/booxter/nix-config/media-repair/internal/jobs"
)

type listFilter struct {
	Service jobs.Service
	State   string
	Query   string
	View    string
}

func readListFilter(query url.Values) listFilter {
	return listFilter{
		Service: jobs.Service(query.Get("service")), State: query.Get("state"),
		Query: strings.TrimSpace(query.Get("q")), View: query.Get("view"),
	}
}

func (filter listFilter) validate() error {
	if filter.Service != "" && filter.Service != jobs.Radarr && filter.Service != jobs.Lidarr {
		return fmt.Errorf("unknown service %q", filter.Service)
	}
	switch filter.View {
	case "", "inbox", "activity", "history":
		return nil
	default:
		return fmt.Errorf("unknown view %q", filter.View)
	}
}

type jobListing struct {
	Items         []item
	InboxCount    int
	ActivityCount int
}

// Count all current jobs in the chosen service before narrowing the list.
// The inbox and activity links show those totals even during a search.
func (app *Handler) filteredJobs(ctx context.Context, filter listFilter) (jobListing, error) {
	var list jobListing
	for _, service := range []jobs.Service{jobs.Lidarr, jobs.Radarr} {
		if filter.Service != "" && service != filter.Service {
			continue
		}
		records, err := app.config.Store.List(ctx, service)
		if err != nil {
			return jobListing{}, err
		}
		for _, job := range records {
			entry := present(job)
			history := !job.InQueue || job.State == jobs.Removed || job.State == jobs.Imported
			inbox := !history && (entry.Attention != nil || job.PendingAction == jobs.ConfirmRemoval)
			if !history {
				list.ActivityCount++
			}
			if inbox {
				list.InboxCount++
			}
			if filter.matches(entry, history, inbox) {
				list.Items = append(list.Items, entry)
			}
		}
	}
	return list, nil
}

func (filter listFilter) matches(entry item, history, inbox bool) bool {
	switch {
	case filter.View == "inbox" && !inbox:
		return false
	case filter.View == "activity" && history:
		return false
	case filter.View == "history" && !history:
		return false
	}
	if filter.State != "" && string(entry.Job.State) != filter.State {
		return false
	}
	if filter.Query == "" {
		return true
	}
	searchable := strings.Join([]string{
		entry.Subject, entry.Job.Title, entry.Status, entry.Explanation, entry.Job.Reason, entry.Job.CollectionError,
	}, " ")
	return strings.Contains(strings.ToLower(searchable), strings.ToLower(filter.Query))
}
