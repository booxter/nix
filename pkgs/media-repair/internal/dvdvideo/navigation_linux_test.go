package dvdvideo

import (
	"context"
	"encoding/binary"
	"encoding/xml"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

func TestIdentifyDVDCellContinuations(t *testing.T) {
	mpeg := dvdFixtureMPEG(t)
	lsdvd, err := exec.LookPath("lsdvd")
	if err != nil {
		t.Fatal(err)
	}

	const continuation = "call vmgm menu 2 resume 1;"
	for _, test := range []struct {
		name           string
		firstCell      string
		lastCell       string
		post           string
		targetCell     string
		targetLastCell string
		noOpCells      bool
		wantNext       int
	}{
		{name: "post command", post: continuation, wantNext: 2},
		{name: "matching final cell", lastCell: continuation, post: continuation, wantNext: 2},
		{
			name: "no-op cells", firstCell: "g0 = 0;", lastCell: "g0 = 0;",
			noOpCells: true, post: continuation, wantNext: 2,
		},
		{
			name: "both titles have final exits", lastCell: continuation, post: continuation,
			targetLastCell: "call vmgm menu 1 resume 1;", wantNext: 2,
		},
		{name: "early exit", firstCell: continuation, post: continuation},
		{name: "conflicting final exit", lastCell: "call vmgm menu 1 resume 1;", post: continuation},
		{name: "final assignment", lastCell: "g6 = 0;", post: continuation},
		{name: "multiple post commands", lastCell: continuation, post: "g6 = 0; " + continuation},
		{name: "destination branches early", post: continuation, targetCell: "call vmgm menu 1 resume 1;"},
	} {
		t.Run(test.name, func(t *testing.T) {
			disc := dvdAuthorFixture{
				Menus: dvdFixtureGroup{Video: dvdFixtureVideo{Format: "pal"}, PGCs: []dvdFixturePGC{
					{Entry: "title", Pre: "exit;"},
					{Pre: "g6 = 1; jump title 2;"},
				}},
				TitleSets: []dvdFixtureTitleSet{
					dvdFixtureTitle(mpeg, test.firstCell, test.lastCell, test.post),
					dvdFixtureTitle(mpeg, test.targetCell, test.targetLastCell, "call vmgm menu 1 resume 1;"),
				},
			}
			// The manager must supply the register that selects chapter one.
			disc.TitleSets[1].Titles.PGCs[0].Pre = "g0 = g6; g6 = 0; if (g0 == 1) break; jump chapter 2;"
			directory := authorDVDFixture(t, disc)
			if test.noOpCells {
				dvdFixtureNoOpCells(t, directory)
			}

			titles, err := (Runner{Executable: lsdvd}).IdentifyDVD(context.Background(), Target{
				NavigationPath: filepath.Join(directory, "VIDEO_TS", "VIDEO_TS.IFO"),
			})
			if err != nil {
				t.Fatal(err)
			}
			if len(titles) != 2 || titles[0].NextTitle != test.wantNext || titles[1].NextTitle != 0 {
				t.Fatalf("DVD continuation: got %+v, want first title to continue to %d", titles, test.wantNext)
			}
		})
	}
}

func TestIdentifyDVDOverlappingTitles(t *testing.T) {
	mpeg := dvdFixtureMPEG(t)
	full := dvdFixturePGC{VOB: &dvdFixtureVOB{File: mpeg, Cells: []dvdFixtureCell{
		{Start: "0", End: "0.6", Chapter: "yes"},
		{Start: "0.6", End: "1.2", Chapter: "yes"},
		{Start: "1.2", Chapter: "yes"},
	}}, Post: "exit;"}
	short := dvdFixturePGC{VOB: &dvdFixtureVOB{File: mpeg, Cells: []dvdFixtureCell{
		full.VOB.Cells[0], full.VOB.Cells[2],
	}}, Post: "exit;"}
	disc := dvdAuthorFixture{
		Menus: dvdFixtureGroup{Video: dvdFixtureVideo{Format: "pal"}, PGCs: []dvdFixturePGC{
			{Entry: "title", Pre: "exit;"},
		}},
		TitleSets: []dvdFixtureTitleSet{{Titles: dvdFixtureGroup{
			Video: dvdFixtureVideo{Format: "pal"}, PGCs: []dvdFixturePGC{full, short},
		}}},
	}
	directory := authorDVDFixture(t, disc)
	lsdvd, err := exec.LookPath("lsdvd")
	if err != nil {
		t.Fatal(err)
	}
	titles, err := (Runner{Executable: lsdvd}).IdentifyDVD(context.Background(), Target{
		NavigationPath: filepath.Join(directory, "VIDEO_TS", "VIDEO_TS.IFO"),
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []Overlap{{Title: 2, SharedDurationMS: 2_400, Ranges: []OverlapRange{
		{StartMS: 0, OtherStartMS: 0, DurationMS: 600},
		{StartMS: 1_200, OtherStartMS: 600, DurationMS: 1_800},
	}}}
	if len(titles) != 2 || !reflect.DeepEqual(titles[0].Overlaps, want) ||
		titles[0].EquivalentTo != 0 || titles[1].EquivalentTo != 0 {
		t.Fatalf("authored DVD overlap: %+v", titles)
	}
}

func dvdFixtureMPEG(t *testing.T) string {
	t.Helper()
	mpeg := filepath.Join(t.TempDir(), "title.mpg")
	runDVDFixtureCommand(t, "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=720x576:r=25",
		"-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", "3", "-target", "pal-dvd", mpeg)
	return mpeg
}

func authorDVDFixture(t *testing.T, disc dvdAuthorFixture) string {
	t.Helper()
	data, err := xml.Marshal(disc)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	configuration := filepath.Join(directory, "dvd.xml")
	if err := os.WriteFile(configuration, data, 0o600); err != nil {
		t.Fatal(err)
	}
	runDVDFixtureCommand(t, "dvdauthor", "-o", directory, "-x", configuration)
	return directory
}

type dvdAuthorFixture struct {
	XMLName   xml.Name             `xml:"dvdauthor"`
	Menus     dvdFixtureGroup      `xml:"vmgm>menus"`
	TitleSets []dvdFixtureTitleSet `xml:"titleset"`
}

type dvdFixtureTitleSet struct {
	Titles dvdFixtureGroup `xml:"titles"`
}

type dvdFixtureGroup struct {
	Video dvdFixtureVideo `xml:"video"`
	PGCs  []dvdFixturePGC `xml:"pgc"`
}

type dvdFixtureVideo struct {
	Format string `xml:"format,attr"`
}

type dvdFixturePGC struct {
	Entry string         `xml:"entry,attr,omitempty"`
	Pre   string         `xml:"pre,omitempty"`
	VOB   *dvdFixtureVOB `xml:"vob,omitempty"`
	Post  string         `xml:"post,omitempty"`
}

type dvdFixtureVOB struct {
	File  string           `xml:"file,attr"`
	Cells []dvdFixtureCell `xml:"cell"`
}

type dvdFixtureCell struct {
	Start   string `xml:"start,attr"`
	End     string `xml:"end,attr,omitempty"`
	Chapter string `xml:"chapter,attr"`
	Command string `xml:",chardata"`
}

func dvdFixtureTitle(mpeg, firstCell, lastCell, post string) dvdFixtureTitleSet {
	vob := dvdFixtureVOB{File: mpeg, Cells: []dvdFixtureCell{
		{Start: "0", End: "1.2", Chapter: "yes", Command: firstCell},
		{Start: "1.2", Chapter: "yes", Command: lastCell},
	}}
	titles := dvdFixtureGroup{
		Video: dvdFixtureVideo{Format: "pal"},
		PGCs:  []dvdFixturePGC{{VOB: &vob, Post: post}},
	}
	return dvdFixtureTitleSet{Titles: titles}
}

func dvdFixtureNoOpCells(t *testing.T, directory string) {
	t.Helper()
	path := filepath.Join(directory, "VIDEO_TS", "VTS_01_0.IFO")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	// dvdauthor requires a cell command to compile to one instruction and has
	// no NOP statement. Replace the authored cell instructions in the DVD's
	// big-endian command table; chapter and playback metadata stay intact.
	word := func(offset int) int { return int(binary.BigEndian.Uint16(data[offset:])) }
	dword := func(offset int) int { return int(binary.BigEndian.Uint32(data[offset:])) }
	chains := dword(0xcc) * 2048
	pgc := chains + dword(chains+12)
	commands := pgc + word(pgc+0xe4)
	cells := commands + 8 + 8*(word(commands)+word(commands+2))
	clear(data[cells : cells+8*word(commands+4)])

	for _, extension := range []string{"IFO", "BUP"} {
		path := filepath.Join(directory, "VIDEO_TS", "VTS_01_0."+extension)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func runDVDFixtureCommand(t *testing.T, name string, args ...string) {
	t.Helper()
	command := exec.Command(name, args...)
	command.Env = append(os.Environ(), "VIDEO_FORMAT=PAL")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("%s: %v: %s", name, err, output)
	}
}
