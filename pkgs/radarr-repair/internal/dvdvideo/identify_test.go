package dvdvideo

import "testing"

func TestDecodeTitlesKeepsDVDNavigationMetadata(t *testing.T) {
	t.Parallel()

	data := []byte(`<lsdvd>
  <track><ix>1</ix><length>9779.000</length><vts>1</vts><ttn>1</ttn>
    <angles>1</angles><format>NTSC</format>
    <audio><format>ac3</format><langcode>xx</langcode></audio>
    <chapter><ix>1</ix></chapter><chapter><ix>2</ix></chapter>
  </track>
  <track><ix>2</ix><length>60.033</length><vts>1</vts><ttn>2</ttn>
    <angles>1</angles><format>NTSC</format><chapter><ix>1</ix></chapter>
  </track>
</lsdvd>`)
	titles, err := decodeTitles(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(titles) != 2 || titles[0].Number != 1 || titles[0].DurationMS != 9_779_000 ||
		titles[0].Chapters != 2 || titles[0].TitleSet != 1 || titles[0].TitleInSet != 1 ||
		len(titles[0].Tracks) != 2 || titles[0].Tracks[1].Codec != "ac3" ||
		titles[0].Tracks[1].Language != "" || titles[1].DurationMS != 60_033 {
		t.Fatalf("decoded DVD titles = %#v", titles)
	}
}

func TestDecodeTitlesRejectsIncompleteNavigation(t *testing.T) {
	t.Parallel()

	for _, data := range []string{
		`<lsdvd/>`,
		`<lsdvd><track><ix>1</ix><length>9779</length></track></lsdvd>`,
		`<lsdvd><track><ix>2</ix><length>9779</length><vts>1</vts><ttn>1</ttn><angles>1</angles><format>NTSC</format><chapter><ix>1</ix></chapter></track></lsdvd>`,
		`<lsdvd><track><ix>1</ix><length>9779</length><vts>1</vts><ttn>1</ttn><angles>1</angles><format>NTSC</format><chapter><ix>2</ix></chapter></track></lsdvd>`,
		`<lsdvd><track><ix>1</ix><length>9779</length><vts>1</vts><ttn>1</ttn><angles>1</angles><format>NTSC</format><audio><format>unknown</format></audio><chapter><ix>1</ix></chapter></track></lsdvd>`,
	} {
		if titles, err := decodeTitles([]byte(data)); err == nil {
			t.Fatalf("accepted incomplete DVD navigation %#v", titles)
		}
	}
}
