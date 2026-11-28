package dvdvideo

import (
	"encoding/xml"
	"reflect"
	"testing"
)

func TestDecodeTitlesDescribesSharedCellsWithoutEquatingTitles(t *testing.T) {
	t.Parallel()
	first := overlapTitle(1, []cellXML{
		overlapCell(1, "6.720", 0, 10),
		overlapCell(2, "17.160", 11, 20),
		overlapCell(3, "60.000", 21, 100),
	})
	second := overlapTitle(2, []cellXML{first.Cells[0], first.Cells[2]})
	second.Cells[1].Number = 2
	titles := decodeOverlapFixture(t, first, second)
	want := []Overlap{{Title: 2, SharedDurationMS: 66_720, Ranges: []OverlapRange{
		{StartMS: 0, OtherStartMS: 0, DurationMS: 6_720},
		{StartMS: 23_880, OtherStartMS: 6_720, DurationMS: 60_000},
	}}}
	if !reflect.DeepEqual(titles[0].Overlaps, want) || titles[0].EquivalentTo != 0 || titles[1].EquivalentTo != 0 {
		t.Fatalf("overlapping title evidence: %+v", titles)
	}
	want[0].Title = 1
	want[0].Ranges[1].StartMS, want[0].Ranges[1].OtherStartMS = 6_720, 23_880
	if !reflect.DeepEqual(titles[1].Overlaps, want) {
		t.Fatalf("reverse overlap: %+v", titles[1].Overlaps)
	}
}

func TestDecodeTitlesDoesNotInferSharedContentFromDuration(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name   string
		change func(*titleXML)
	}{
		{"different title set", func(title *titleXML) { title.TitleSet = 2 }},
		{"different sectors", func(title *titleXML) { title.Cells[0].FirstSector = ptrSector(1) }},
		{"different cell", func(title *titleXML) { title.Cells[0].Cell = 2 }},
		{"different VOB", func(title *titleXML) { title.Cells[0].VOB = 2 }},
		{"missing identity", func(title *titleXML) { title.Cells[0].FirstSector = nil }},
		{"repeated cell", func(title *titleXML) {
			title.Cells = append(title.Cells, title.Cells[0])
			title.Cells[1].Number = 2
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			first := overlapTitle(1, []cellXML{overlapCell(1, "60.000", 0, 100)})
			second := overlapTitle(2, []cellXML{overlapCell(1, "60.000", 0, 100)})
			test.change(&second)
			titles := decodeOverlapFixture(t, first, second)
			if len(titles[0].Overlaps) != 0 || len(titles[1].Overlaps) != 0 {
				t.Fatalf("unproven overlap: %+v", titles)
			}
		})
	}
}

func TestDecodeTitlesPreservesSharedContentOrder(t *testing.T) {
	t.Parallel()
	first := overlapTitle(1, []cellXML{
		overlapCell(1, "30.000", 0, 10), overlapCell(2, "30.000", 11, 20),
	})
	second := overlapTitle(2, []cellXML{first.Cells[1], first.Cells[0]})
	second.Cells[0].Number, second.Cells[1].Number = 1, 2
	titles := decodeOverlapFixture(t, first, second)
	want := []OverlapRange{
		{StartMS: 0, OtherStartMS: 30_000, DurationMS: 30_000},
		{StartMS: 30_000, OtherStartMS: 0, DurationMS: 30_000},
	}
	if len(titles[0].Overlaps) != 1 || !reflect.DeepEqual(titles[0].Overlaps[0].Ranges, want) {
		t.Fatalf("reordered overlap: %+v", titles[0].Overlaps)
	}
}

func overlapTitle(number int, cells []cellXML) titleXML {
	return titleXML{
		Number: number, Length: "120.000", TitleSet: 1, TitleInSet: number,
		Angles: 1, Video: "PAL", Chapters: []chapterXML{{Number: 1}}, Cells: cells,
	}
}

func overlapCell(number int, length string, first, last uint32) cellXML {
	return cellXML{
		Number: number, Length: length, VOB: 1, Cell: number,
		FirstSector: ptrSector(first), LastSector: ptrSector(last),
	}
}

func ptrSector(value uint32) *uint32 { return &value }

func decodeOverlapFixture(t *testing.T, raw ...titleXML) []Title {
	t.Helper()
	data, err := xml.Marshal(discXML{Titles: raw})
	if err != nil {
		t.Fatal(err)
	}
	titles, err := decodeTitles(data)
	if err != nil {
		t.Fatal(err)
	}
	return titles
}
