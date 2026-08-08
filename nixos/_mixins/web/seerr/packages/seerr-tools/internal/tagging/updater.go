package tagging

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
	"unicode"

	"github.com/booxter/nix-config/seerr-tools/internal/seerr"
	"github.com/booxter/nix-config/seerr-tools/internal/servarr"
	"github.com/golusoris/goenvoy/arr/v2"
	"golang.org/x/text/unicode/norm"
)

type Catalog interface {
	Items(context.Context, seerr.ServiceKind, seerr.Service) ([]servarr.Item, error)
	Tags(context.Context, seerr.ServiceKind, seerr.Service) ([]arr.Tag, error)
	CreateTag(context.Context, seerr.ServiceKind, seerr.Service, string) (arr.Tag, error)
	AddTag(context.Context, seerr.ServiceKind, seerr.Service, []int, int) error
}

type Options struct {
	Apply     bool
	Verbose   bool
	BatchSize int
	UserIDs   []int
}

type Stats struct {
	Requests           int
	EligibleRequests   int
	UniqueAttributions int
	TagsToCreate       int
	ItemsToUpdate      int
	AlreadyTagged      int
	MissingItems       int
	SkippedRequests    int
}

type serviceKey struct {
	kind seerr.ServiceKind
	id   int
}

type attribution struct {
	users map[int]seerr.User
	items map[serviceKey]map[int]map[int]bool
	stats Stats
}

func Update(
	ctx context.Context,
	requests []seerr.Request,
	radarrServices []seerr.Service,
	sonarrServices []seerr.Service,
	catalog Catalog,
	options Options,
	output io.Writer,
) (Stats, error) {
	if options.BatchSize < 1 {
		return Stats{}, fmt.Errorf("batch size must be positive")
	}
	services := indexServices(radarrServices, sonarrServices)
	if !hasTaggingService(services) {
		return Stats{}, fmt.Errorf("no Radarr or Sonarr instances have requester tagging enabled")
	}
	desired := collectAttributions(requests, services, options.UserIDs)
	mode := "DRY RUN: no changes will be made"
	if options.Apply {
		mode = "APPLY: changes will be written"
	}
	fmt.Fprintln(output, mode)

	keys := make([]serviceKey, 0, len(desired.items))
	for key := range desired.items {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(left, right int) bool {
		if keys[left].kind == keys[right].kind {
			return keys[left].id < keys[right].id
		}
		return keys[left].kind < keys[right].kind
	})
	for _, key := range keys {
		service := services[key]
		if err := updateService(ctx, key, service, desired, catalog, options, output); err != nil {
			return Stats{}, err
		}
	}
	renderSummary(output, desired.stats, options.Apply)
	return desired.stats, nil
}

func indexServices(radarrServices, sonarrServices []seerr.Service) map[serviceKey]seerr.Service {
	services := make(map[serviceKey]seerr.Service, len(radarrServices)+len(sonarrServices))
	for _, service := range radarrServices {
		services[serviceKey{seerr.Radarr, service.ID}] = service
	}
	for _, service := range sonarrServices {
		services[serviceKey{seerr.Sonarr, service.ID}] = service
	}
	return services
}

func hasTaggingService(services map[serviceKey]seerr.Service) bool {
	for _, service := range services {
		if service.TagRequests {
			return true
		}
	}
	return false
}

func collectAttributions(
	requests []seerr.Request,
	services map[serviceKey]seerr.Service,
	selectedUsers []int,
) *attribution {
	selected := make(map[int]bool, len(selectedUsers))
	for _, userID := range selectedUsers {
		selected[userID] = true
	}
	result := &attribution{
		users: make(map[int]seerr.User),
		items: make(map[serviceKey]map[int]map[int]bool),
		stats: Stats{Requests: len(requests)},
	}
	for _, request := range requests {
		if request.Status != seerr.RequestApproved && request.Status != seerr.RequestCompleted {
			result.stats.SkippedRequests++
			continue
		}
		if request.RequestedBy == nil || request.RequestedBy.DisplayName == "" {
			result.stats.SkippedRequests++
			continue
		}
		user := *request.RequestedBy
		if len(selected) != 0 && !selected[user.ID] {
			continue
		}
		kind, externalID, ok := requestTarget(request)
		if !ok {
			result.stats.SkippedRequests++
			continue
		}
		serviceID, ok := request.ServiceID()
		if !ok {
			result.stats.SkippedRequests++
			continue
		}
		key := serviceKey{kind, serviceID}
		service, ok := services[key]
		if !ok || !service.TagRequests {
			result.stats.SkippedRequests++
			continue
		}
		result.users[user.ID] = user
		if result.items[key] == nil {
			result.items[key] = make(map[int]map[int]bool)
		}
		if result.items[key][user.ID] == nil {
			result.items[key][user.ID] = make(map[int]bool)
		}
		result.items[key][user.ID][externalID] = true
		result.stats.EligibleRequests++
	}
	for _, users := range result.items {
		for _, externalIDs := range users {
			result.stats.UniqueAttributions += len(externalIDs)
		}
	}
	return result
}

func requestTarget(request seerr.Request) (seerr.ServiceKind, int, bool) {
	if request.Media == nil {
		return "", 0, false
	}
	switch request.Type {
	case "movie":
		if request.Media.TmdbID != nil {
			return seerr.Radarr, *request.Media.TmdbID, true
		}
	case "tv":
		if request.Media.TvdbID != nil {
			return seerr.Sonarr, *request.Media.TvdbID, true
		}
	}
	return "", 0, false
}

func updateService(
	ctx context.Context,
	key serviceKey,
	service seerr.Service,
	desired *attribution,
	catalog Catalog,
	options Options,
	output io.Writer,
) error {
	items, err := catalog.Items(ctx, key.kind, service)
	if err != nil {
		return fmt.Errorf("read %s %q items: %w", key.kind, service.Name, err)
	}
	inventory := make(map[int]servarr.Item, len(items))
	for _, item := range items {
		inventory[item.ExternalID] = item
	}
	tags, err := catalog.Tags(ctx, key.kind, service)
	if err != nil {
		return fmt.Errorf("read %s %q tags: %w", key.kind, service.Name, err)
	}
	name := service.Name
	if name == "" {
		name = fmt.Sprint(service.ID)
	}
	fmt.Fprintf(output, "\n%s %s: %d items, %d tags\n", titleKind(key.kind), name, len(items), len(tags))

	userIDs := make([]int, 0, len(desired.items[key]))
	for userID := range desired.items[key] {
		userIDs = append(userIDs, userID)
	}
	sort.Ints(userIDs)
	for _, userID := range userIDs {
		if err := updateUser(ctx, key.kind, service, desired, inventory, &tags, userID, catalog, options, output); err != nil {
			return err
		}
	}
	return nil
}

func updateUser(
	ctx context.Context,
	kind seerr.ServiceKind,
	service seerr.Service,
	desired *attribution,
	inventory map[int]servarr.Item,
	tags *[]arr.Tag,
	userID int,
	catalog Catalog,
	options Options,
	output io.Writer,
) error {
	tag, found := findUserTag(*tags, userID)
	label := tag.Label
	if !found {
		label = expectedTag(desired.users[userID])
	}
	externalIDs := desired.items[serviceKey{kind, service.ID}][userID]
	targets := make([]servarr.Item, 0, len(externalIDs))
	for externalID := range externalIDs {
		item, ok := inventory[externalID]
		if !ok {
			desired.stats.MissingItems++
			if options.Verbose {
				fmt.Fprintf(output, "  MISSING %s: external ID %d\n", label, externalID)
			}
			continue
		}
		if found && contains(item.Tags, tag.ID) {
			desired.stats.AlreadyTagged++
			continue
		}
		targets = append(targets, item)
	}
	if len(targets) == 0 {
		return nil
	}
	if !found {
		desired.stats.TagsToCreate++
		action := "WOULD CREATE"
		if options.Apply {
			action = "CREATE"
		}
		fmt.Fprintf(output, "  %s tag %s\n", action, label)
		if options.Apply {
			created, err := catalog.CreateTag(ctx, kind, service, label)
			if err != nil {
				return fmt.Errorf("create %s %q tag %q: %w", kind, service.Name, label, err)
			}
			tag = created
			*tags = append(*tags, created)
		}
	}
	sort.Slice(targets, func(left, right int) bool { return targets[left].ID < targets[right].ID })
	desired.stats.ItemsToUpdate += len(targets)
	action := "WOULD ADD"
	if options.Apply {
		action = "ADD"
	}
	noun := "series"
	if kind == seerr.Radarr {
		noun = "movies"
	}
	fmt.Fprintf(output, "  %s %s to %d %s\n", action, label, len(targets), noun)
	if options.Verbose {
		titles := append([]servarr.Item(nil), targets...)
		sort.Slice(titles, func(left, right int) bool { return titles[left].Title < titles[right].Title })
		for _, item := range titles {
			title := item.Title
			if title == "" {
				title = fmt.Sprint(item.ID)
			}
			fmt.Fprintf(output, "    - %s\n", title)
		}
	}
	if !options.Apply {
		return nil
	}
	itemIDs := make([]int, len(targets))
	for index, item := range targets {
		itemIDs[index] = item.ID
	}
	for offset := 0; offset < len(itemIDs); offset += options.BatchSize {
		end := min(offset+options.BatchSize, len(itemIDs))
		if err := catalog.AddTag(ctx, kind, service, itemIDs[offset:end], tag.ID); err != nil {
			return fmt.Errorf("add %s %q tag %q: %w", kind, service.Name, label, err)
		}
	}
	return nil
}

func contains(values []int, target int) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func findUserTag(tags []arr.Tag, userID int) (arr.Tag, bool) {
	currentPrefix := fmt.Sprintf("%d-", userID)
	legacyPrefix := fmt.Sprintf("%d - ", userID)
	for _, tag := range tags {
		if strings.HasPrefix(tag.Label, currentPrefix) || strings.HasPrefix(tag.Label, legacyPrefix) {
			return tag, true
		}
	}
	return arr.Tag{}, false
}

func expectedTag(user seerr.User) string {
	return fmt.Sprintf("%d-%s", user.ID, sanitizeDisplayName(user.DisplayName))
}

func sanitizeDisplayName(displayName string) string {
	var label strings.Builder
	separator := false
	for _, character := range norm.NFD.String(displayName) {
		if unicode.Is(unicode.Mn, character) {
			continue
		}
		if unicode.IsSpace(character) || character == '-' {
			separator = label.Len() != 0
			continue
		}
		if !isASCIIAlphanumeric(character) {
			continue
		}
		if separator {
			label.WriteByte('-')
			separator = false
		}
		label.WriteRune(character)
	}
	return strings.Trim(label.String(), "-")
}

func isASCIIAlphanumeric(character rune) bool {
	return character >= 'a' && character <= 'z' ||
		character >= 'A' && character <= 'Z' ||
		character >= '0' && character <= '9'
}

func titleKind(kind seerr.ServiceKind) string {
	if kind == seerr.Radarr {
		return "Radarr"
	}
	return "Sonarr"
}

func renderSummary(output io.Writer, stats Stats, apply bool) {
	tagAction := "to create"
	itemAction := "to update"
	if apply {
		tagAction = "created"
		itemAction = "updated"
	}
	fmt.Fprintln(output, "\nSummary:")
	fmt.Fprintf(output, "  requests scanned: %d\n", stats.Requests)
	fmt.Fprintf(output, "  eligible requests: %d\n", stats.EligibleRequests)
	fmt.Fprintf(output, "  unique user/item attributions: %d\n", stats.UniqueAttributions)
	fmt.Fprintf(output, "  tags %s: %d\n", tagAction, stats.TagsToCreate)
	fmt.Fprintf(output, "  items %s: %d\n", itemAction, stats.ItemsToUpdate)
	fmt.Fprintf(output, "  items already tagged: %d\n", stats.AlreadyTagged)
	fmt.Fprintf(output, "  requested items absent from Radarr/Sonarr: %d\n", stats.MissingItems)
	fmt.Fprintf(output, "  requests skipped: %d\n", stats.SkippedRequests)
}
