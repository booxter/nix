package servarr

import (
	"context"
	"fmt"
)

const (
	QueuePageSize       = 250
	MaximumQueuePages   = 100
	MaximumQueueRecords = 10_000
)

type QueuePage[Record any] struct {
	Number       int
	Size         int
	TotalRecords int
	Records      []Record
}

type QueuePageReader[Record any] func(
	context.Context,
	int,
	int,
) (QueuePage[Record], error)

func ReadQueue[Record any](
	ctx context.Context,
	service string,
	readPage QueuePageReader[Record],
) ([]Record, error) {
	if service == "" || readPage == nil {
		return nil, fmt.Errorf("Servarr queue reader needs a service name and page reader")
	}
	records := make([]Record, 0)
	expectedTotal := -1

	for pageNumber := 1; pageNumber <= MaximumQueuePages; pageNumber++ {
		page, err := readPage(ctx, pageNumber, QueuePageSize)
		if err != nil {
			return nil, err
		}
		if err := validateQueuePage(service, pageNumber, page, expectedTotal, len(records)); err != nil {
			return nil, err
		}
		if expectedTotal == -1 {
			expectedTotal = page.TotalRecords
		}
		records = append(records, page.Records...)

		switch {
		case len(records) == expectedTotal:
			return records, nil
		case len(records) > expectedTotal:
			return nil, fmt.Errorf(
				"%s queue returned %d records for a reported total of %d",
				service,
				len(records),
				expectedTotal,
			)
		case len(page.Records) == 0:
			return nil, fmt.Errorf(
				"%s queue page %d was empty before the reported total of %d",
				service,
				pageNumber,
				expectedTotal,
			)
		}
	}

	return nil, fmt.Errorf("%s queue exceeds %d pages", service, MaximumQueuePages)
}

func validateQueuePage[Record any](
	service string,
	expectedNumber int,
	page QueuePage[Record],
	expectedTotal int,
	collected int,
) error {
	if page.Number != expectedNumber {
		return fmt.Errorf(
			"%s queue requested page %d but received page %d",
			service,
			expectedNumber,
			page.Number,
		)
	}
	if page.Size <= 0 || page.Size > QueuePageSize || len(page.Records) > page.Size {
		return fmt.Errorf(
			"%s queue page %d has invalid page size %d",
			service,
			expectedNumber,
			page.Size,
		)
	}
	if page.TotalRecords < 0 || page.TotalRecords > MaximumQueueRecords {
		return fmt.Errorf(
			"%s queue page %d has invalid total %d",
			service,
			expectedNumber,
			page.TotalRecords,
		)
	}
	if expectedTotal >= 0 && page.TotalRecords != expectedTotal {
		return fmt.Errorf(
			"%s queue total changed from %d to %d while reading page %d",
			service,
			expectedTotal,
			page.TotalRecords,
			expectedNumber,
		)
	}
	if collected+len(page.Records) > MaximumQueueRecords {
		return fmt.Errorf("%s queue exceeds %d records", service, MaximumQueueRecords)
	}
	return nil
}
