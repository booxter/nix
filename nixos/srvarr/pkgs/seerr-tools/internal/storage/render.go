package storage

import (
	"fmt"
	"io"

	"github.com/dustin/go-humanize"
	"github.com/jedib0t/go-pretty/v6/table"
)

func formatBytes(value int64) string {
	if value < 0 {
		return "-" + humanize.IBytes(uint64(-value))
	}
	return humanize.IBytes(uint64(value))
}

func Render(writer io.Writer, report Report) {
	output := table.NewWriter()
	output.SetOutputMirror(writer)
	output.SetStyle(table.StyleLight)
	output.AppendHeader(table.Row{
		"ID", "User", "Movies", "Movie data", "Series", "Seasons",
		"TV data", "Files", "Logical", "Allocated", "Share", "Exclusive",
	})
	for _, row := range report.Users {
		output.AppendRow(table.Row{
			row.UserID,
			row.DisplayName,
			row.Movies,
			formatBytes(row.MovieBytes),
			row.Series,
			row.Seasons,
			formatBytes(row.TVBytes),
			row.Files,
			formatBytes(row.LogicalBytes),
			formatBytes(row.AllocatedBytes),
			fmt.Sprintf("%.1f%%", row.AllocatedPercent),
			formatBytes(row.ExclusiveBytes),
		})
	}
	output.Render()

	fmt.Fprintf(
		writer,
		"\nDistinct attributed storage: %s (%s movies, %s TV) across %d files (%d shared)\n",
		formatBytes(report.Totals.DistinctBytes),
		formatBytes(report.Totals.MovieBytes),
		formatBytes(report.Totals.TVBytes),
		report.Totals.Files,
		report.Totals.SharedFiles,
	)
	fmt.Fprintf(writer, "Logical per-user total: %s\n", formatBytes(report.Totals.LogicalBytes))
	fmt.Fprintf(
		writer,
		"Requests: %d scanned, %d eligible, %d skipped\n",
		report.Requests.Scanned,
		report.Requests.Eligible,
		report.Requests.Skipped,
	)
	fmt.Fprintf(
		writer,
		"Unresolved: %d movies absent from Radarr, %d movies without files, %d series absent from Sonarr, %d seasons without files\n\n",
		report.Unresolved.MoviesNotInRadarr,
		report.Unresolved.MoviesWithoutFiles,
		report.Unresolved.SeriesNotInSonarr,
		report.Unresolved.SeasonsWithoutFiles,
	)
	fmt.Fprintln(
		writer,
		"Logical counts each file in full for every requester; Allocated splits shared files evenly; Exclusive includes files attributed to only one user.",
	)
}
