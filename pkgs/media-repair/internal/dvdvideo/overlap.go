package dvdvideo

import (
	"math"
	"strconv"
)

// Overlap describes shared source cells, not equivalent titles or a preferred cut.
type Overlap struct {
	Title            int
	SharedDurationMS int64
	Ranges           []OverlapRange
}

type OverlapRange struct {
	StartMS      int64
	OtherStartMS int64
	DurationMS   int64
}

type cellXML struct {
	Number      int     `xml:"ix"`
	Length      string  `xml:"length"`
	VOB         int     `xml:"vob_id"`
	Cell        int     `xml:"cell_id"`
	FirstSector *uint32 `xml:"first_sector"`
	LastSector  *uint32 `xml:"last_sector"`
}

type cellIdentity struct {
	vob, cell               int
	firstSector, lastSector uint32
	durationMS              int64
}

type playbackCell struct {
	identity cellIdentity
	startMS  int64
}

func playbackCells(raw titleXML) []playbackCell {
	if len(raw.Cells) == 0 || len(raw.Cells) > 255 {
		return nil
	}
	cells := make([]playbackCell, 0, len(raw.Cells))
	seen := make(map[cellIdentity]bool, len(raw.Cells))
	var start int64
	for index, cell := range raw.Cells {
		seconds, err := strconv.ParseFloat(cell.Length, 64)
		if err != nil || math.IsNaN(seconds) || math.IsInf(seconds, 0) ||
			seconds <= 0 || seconds > 7*24*60*60 || cell.Number != index+1 ||
			cell.VOB <= 0 || cell.VOB > 65535 || cell.Cell <= 0 || cell.Cell > 255 ||
			cell.FirstSector == nil || cell.LastSector == nil || *cell.FirstSector > *cell.LastSector {
			return nil
		}
		identity := cellIdentity{
			vob: cell.VOB, cell: cell.Cell, firstSector: *cell.FirstSector,
			lastSector: *cell.LastSector, durationMS: int64(math.Round(seconds * 1000)),
		}
		// Repeated cells have ambiguous timeline matches. Leave them unclassified.
		if seen[identity] {
			return nil
		}
		seen[identity] = true
		cells = append(cells, playbackCell{identity: identity, startMS: start})
		start += identity.durationMS
	}
	return cells
}

func withOverlaps(titles []Title, raw []titleXML) []Title {
	cells := make([][]playbackCell, len(titles))
	for index := range titles {
		cells[index] = playbackCells(raw[index])
	}
	for left := range titles {
		for right := left + 1; right < len(titles); right++ {
			if titles[left].TitleSet != titles[right].TitleSet {
				continue
			}
			ranges := sharedRanges(cells[left], cells[right])
			if len(ranges) == 0 {
				continue
			}
			forward := Overlap{Title: titles[right].Number, Ranges: ranges}
			reverse := Overlap{Title: titles[left].Number}
			for _, part := range ranges {
				forward.SharedDurationMS += part.DurationMS
				reverse.Ranges = append(reverse.Ranges, OverlapRange{
					StartMS: part.OtherStartMS, OtherStartMS: part.StartMS, DurationMS: part.DurationMS,
				})
			}
			reverse.SharedDurationMS = forward.SharedDurationMS
			titles[left].Overlaps = append(titles[left].Overlaps, forward)
			titles[right].Overlaps = append(titles[right].Overlaps, reverse)
		}
	}
	return titles
}

func sharedRanges(left, right []playbackCell) []OverlapRange {
	positions := make(map[cellIdentity]int64, len(right))
	for _, cell := range right {
		positions[cell.identity] = cell.startMS
	}
	var ranges []OverlapRange
	for _, cell := range left {
		otherStart, found := positions[cell.identity]
		if !found {
			continue
		}
		if len(ranges) > 0 {
			last := &ranges[len(ranges)-1]
			if last.StartMS+last.DurationMS == cell.startMS &&
				last.OtherStartMS+last.DurationMS == otherStart {
				last.DurationMS += cell.identity.durationMS
				continue
			}
		}
		ranges = append(ranges, OverlapRange{
			StartMS: cell.startMS, OtherStartMS: otherStart, DurationMS: cell.identity.durationMS,
		})
	}
	return ranges
}
