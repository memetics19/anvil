package media

import (
	"reflect"
	"strings"
	"testing"
)

const movieLibrary = `[
 {"id":7,"title":"Dune","year":1984,"sizeOnDisk":2147483648},
 {"id":8,"title":"Dune","year":2021,"sizeOnDisk":13421772800},
 {"id":9,"title":"Dunkirk","year":2017,"sizeOnDisk":1073741824}]`

func TestMediaDeleteAsksWhichOneThenConfirms(t *testing.T) {
	radarr := &fakeArr{library: movieLibrary,
		queue: `{"records":[{"id":31,"movieId":8},{"id":32,"movieId":9}]}`}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("2\ny\n", "media", "delete", "dune"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	want := []string{
		"queue/31?removeFromClient=true&blocklist=false",
		"movie/8?deleteFiles=true&addImportExclusion=false&addImportListExclusion=false",
	}
	if !reflect.DeepEqual(radarr.deletes, want) {
		t.Errorf("deletes = %q, want %q", radarr.deletes, want)
	}
	out := l.Out.String()
	for _, s := range []string{"1. Dune (1984)  [2.0 GB]", "2. Dune (2021)  [12.5 GB]", "Which one? [1-2]",
		"Delete Dune (2021) and its files (12.5 GB)? [y/N]", "Stopped 1 download(s)."} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in:\n%s", s, out)
		}
	}
	if strings.Contains(out, "Dunkirk") {
		t.Errorf("a title without the word was listed:\n%s", out)
	}
	noKeyIn(t, l)
}

func TestMediaDeleteSeriesKeepFilesYes(t *testing.T) {
	sonarr := &fakeArr{tv: true, library: `[{"id":5,"title":"The Expanse","year":2015,"statistics":{"sizeOnDisk":1073741824}}]`,
		queue: `{"records":[{"id":40,"seriesId":5},{"id":41,"seriesId":6}]}`}
	l := mediaLab(t, &fakeArr{}, sonarr)
	if code := l.Run("", "media", "delete", "expanse", "--tv", "--keep-files", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	want := []string{
		"queue/40?removeFromClient=true&blocklist=false",
		"series/5?deleteFiles=false&addImportExclusion=false&addImportListExclusion=false",
	}
	if !reflect.DeepEqual(sonarr.deletes, want) {
		t.Errorf("deletes = %q, want %q", sonarr.deletes, want)
	}
	if out := l.Out.String(); strings.Contains(out, "[y/N]") || !strings.Contains(out, "Deleted The Expanse (2015) from Sonarr, keeping its files.") {
		t.Errorf("output:\n%s", out)
	}
}

func TestMediaDeleteNoDeletesNothing(t *testing.T) {
	radarr := &fakeArr{library: movieLibrary}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	for _, in := range []string{"n\n", ""} {
		if code := l.Run(in, "media", "delete", "dunkirk"); code != 1 || !strings.Contains(l.Out.String(), "Nothing deleted.") {
			t.Errorf("answer %q: exit %d, output:\n%s", in, code, l.Out.String())
		}
	}
	if len(radarr.deletes) != 0 {
		t.Errorf("deleted after a no: %q", radarr.deletes)
	}
}

func TestMediaDeleteNoMatch(t *testing.T) {
	radarr := &fakeArr{library: movieLibrary}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "delete", "interstellar"); code != 1 || !strings.Contains(l.Out.String(), `No movie in the library matches "interstellar".`) {
		t.Errorf("exit %d, output:\n%s", code, l.Out.String())
	}
	if code := l.Run("", "media", "delete", "dune", "--pick", "5"); code != 2 {
		t.Errorf("--pick past the list: exit %d", code)
	}
	if len(radarr.deletes) != 0 {
		t.Errorf("deleted: %q", radarr.deletes)
	}
}

func TestLabelYearOnce(t *testing.T) {
	for _, c := range []struct {
		it   item
		want string
	}{
		{item{Title: "Dune", Year: 2021}, "Dune (2021)"},
		{item{Title: "The Body (2026)", Year: 2026}, "The Body (2026)"},
		{item{Title: "Untitled"}, "Untitled"},
	} {
		if got := c.it.label(); got != c.want {
			t.Errorf("label(%q, %d) = %q, want %q", c.it.Title, c.it.Year, got, c.want)
		}
	}
}
