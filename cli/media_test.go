package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

const testArrSentinel = "sentinel-arr-value-7d31"

// fakeArr is Radarr (or Sonarr with tv) for the tests. It answers the calls anvil media
// makes and records the bodies it is sent.
type fakeArr struct {
	tv       bool
	lookup   string // JSON array for */lookup
	queue    string // JSON object for queue
	missing  string // JSON object for wanted/missing
	free     int64
	mu       sync.Mutex
	posts    map[string][]map[string]any
	badKey   bool
	addError int
}

func (f *fakeArr) server(t *testing.T) *httptest.Server {
	t.Helper()
	f.posts = map[string][]map[string]any{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Api-Key") != testArrSentinel {
			f.badKey = true
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		p := strings.TrimPrefix(r.URL.Path, "/api/v3/")
		if r.Method == http.MethodPost {
			var body map[string]any
			b, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(b, &body)
			f.mu.Lock()
			f.posts[p] = append(f.posts[p], body)
			f.mu.Unlock()
			if f.addError != 0 && (p == "movie" || p == "series") {
				w.WriteHeader(f.addError)
				_, _ = io.WriteString(w, `[{"errorMessage":"This movie has already been added"}]`)
				return
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{}`)
			return
		}
		switch {
		case strings.HasSuffix(p, "/lookup"):
			_, _ = io.WriteString(w, f.lookup)
		case p == "qualityprofile":
			_, _ = io.WriteString(w, `[{"id":1,"name":"Any"},{"id":4,"name":"HD-1080p"},{"id":5,"name":"Ultra-HD"}]`)
		case p == "rootfolder":
			root := "/movies"
			if f.tv {
				root = "/tv"
			}
			_ = json.NewEncoder(w).Encode([]map[string]any{{"path": root, "freeSpace": f.free}})
		case p == "queue":
			_, _ = io.WriteString(w, or(f.queue, `{"records":[]}`))
		case p == "wanted/missing":
			_, _ = io.WriteString(w, or(f.missing, `{"records":[]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func or(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

const twoMovies = `[
 {"title":"Dune","year":2021,"tmdbId":438631,"overview":"Paul Atreides goes to Arrakis.","titleSlug":"dune-438631"},
 {"title":"Dune","year":1984,"tmdbId":841,"overview":"The 1984 film."}]`

// mediaLab is a test lab whose media endpoints are two fake servers.
func mediaLab(t *testing.T, radarr, sonarr *fakeArr) *testLab {
	t.Helper()
	l := newTestLab(t)
	rs, ss := radarr.server(t), sonarr.server(t)
	old := mediaEnv
	mediaEnv = func(*app) (mediaConfig, error) {
		return mediaConfig{Radarr: arrEndpoint{rs.URL, testArrSentinel}, Sonarr: arrEndpoint{ss.URL, testArrSentinel}}, nil
	}
	t.Cleanup(func() { mediaEnv = old })
	return l
}

func noKeyIn(t *testing.T, l *testLab) {
	t.Helper()
	if strings.Contains(l.out.String()+l.err.String(), testArrSentinel) {
		t.Fatalf("the API key reached the output:\n%s%s", l.out.String(), l.err.String())
	}
}

func TestMediaSearchListsMatches(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Dune","year":2021,"overview":"x"},{"title":"Dune","year":1984,"id":7,"hasFile":true}]`}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("", "media", "search", "dune"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	out := l.out.String()
	for _, want := range []string{"1. Dune (2021)", "2. Dune (1984)  [in the library]"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	noKeyIn(t, l)
}

func TestMediaGetAsksWhichOneAndAddsWithSearch(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("1\n", "media", "get", "dune"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	adds := radarr.posts["movie"]
	if len(adds) != 1 {
		t.Fatalf("want one add, got %d", len(adds))
	}
	got := adds[0]
	if got["tmdbId"] != float64(438631) || got["qualityProfileId"] != float64(4) || got["rootFolderPath"] != "/movies" || got["monitored"] != true {
		t.Errorf("add body = %v", got)
	}
	if opts, _ := got["addOptions"].(map[string]any); opts["searchForMovie"] != true {
		t.Errorf("the add does not start a search: %v", got["addOptions"])
	}
	if !strings.Contains(l.out.String(), "Which one? [1-2]") || !strings.Contains(l.out.String(), "Added Dune (2021) (HD-1080p") {
		t.Errorf("output:\n%s", l.out.String())
	}
	noKeyIn(t, l)
}

func TestMediaGetPickAndQuality(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("", "media", "get", "dune", "--pick", "2", "--quality", "ultra-hd"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	got := radarr.posts["movie"][0]
	if got["tmdbId"] != float64(841) || got["qualityProfileId"] != float64(5) {
		t.Errorf("add body = %v", got)
	}
	if strings.Contains(l.out.String(), "Which one?") {
		t.Error("--pick still asked")
	}
}

func TestMediaGetUnknownQualityNamesTheProfiles(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("", "media", "get", "dune", "--pick", "1", "--quality", "4K"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.Contains(l.err.String(), `no quality profile "4K" (it has: Any, HD-1080p, Ultra-HD)`) {
		t.Errorf("stderr: %s", l.err.String())
	}
	if len(radarr.posts["movie"]) != 0 {
		t.Error("added despite the unknown profile")
	}
}

func TestMediaGetNoAnswerAddsNothing(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("", "media", "get", "dune"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if len(radarr.posts["movie"]) != 0 || !strings.Contains(l.out.String(), "Nothing added.") {
		t.Errorf("posts %v, output:\n%s", radarr.posts, l.out.String())
	}
}

func TestMediaGetLowSpaceAsks(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Dune","year":2021,"tmdbId":1}]`, free: 3 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("n\n", "media", "get", "dune"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if len(radarr.posts["movie"]) != 0 || !strings.Contains(l.out.String(), "Only 3.0 GB free in /movies.") {
		t.Errorf("output:\n%s", l.out.String())
	}
	if code := l.run("", "media", "get", "dune", "--yes"); code != 0 {
		t.Fatalf("--yes: exit %d: %s", code, l.err.String())
	}
	if len(radarr.posts["movie"]) != 1 {
		t.Error("--yes did not add")
	}
}

func TestMediaGetExistingSearchesAgain(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Inherent Vice","year":2014,"id":12,"hasFile":false}]`}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("", "media", "get", "inherent vice"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	cmds := radarr.posts["command"]
	if len(cmds) != 1 || cmds[0]["name"] != "MoviesSearch" || len(radarr.posts["movie"]) != 0 {
		t.Fatalf("posts = %v", radarr.posts)
	}
	ids, _ := cmds[0]["movieIds"].([]any)
	if len(ids) != 1 || ids[0] != float64(12) {
		t.Errorf("movieIds = %v", cmds[0]["movieIds"])
	}
}

func TestMediaGetSeries(t *testing.T) {
	sonarr := &fakeArr{tv: true, lookup: `[{"title":"The Expanse","year":2015,"tvdbId":280619}]`, free: 200 << 30}
	l := mediaLab(t, &fakeArr{}, sonarr)
	if code := l.run("", "media", "get", "the", "expanse", "--tv"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	got := sonarr.posts["series"][0]
	opts, _ := got["addOptions"].(map[string]any)
	if got["tvdbId"] != float64(280619) || got["rootFolderPath"] != "/tv" || got["seasonFolder"] != true ||
		opts["searchForMissingEpisodes"] != true || opts["monitor"] != "all" {
		t.Errorf("add body = %v", got)
	}
}

func TestMediaGetShowsArrError(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Dune","year":2021,"tmdbId":1}]`, free: 200 << 30, addError: 400}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.run("", "media", "get", "dune"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.Contains(l.err.String(), "This movie has already been added") {
		t.Errorf("stderr: %s", l.err.String())
	}
	noKeyIn(t, l)
}

func TestMediaStatus(t *testing.T) {
	radarr := &fakeArr{free: 19 << 30,
		queue: `{"records":[{"title":"Dune.2021.1080p","size":4000,"sizeleft":1000,"timeleft":"00:12:00",
		  "trackedDownloadState":"downloading","trackedDownloadStatus":"ok","movie":{"title":"Dune","year":2021}},
		  {"title":"x","size":100,"sizeleft":100,"trackedDownloadState":"importPending","trackedDownloadStatus":"warning",
		  "statusMessages":[{"messages":["No files found are eligible for import"]}],"movie":{"title":"Heat","year":1995}}]}`,
		missing: `{"records":[{"title":"Dune","year":2021},{"title":"Inherent Vice","year":2014}]}`}
	sonarr := &fakeArr{tv: true, free: 19 << 30,
		missing: `{"records":[{"series":{"title":"Angie Tribeca"}},{"series":{"title":"Angie Tribeca"}}]}`}
	l := mediaLab(t, radarr, sonarr)
	if code := l.run("", "media", "status"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	out := l.out.String()
	for _, want := range []string{
		" 75%  Dune (2021)", "eta 00:12:00", "downloading",
		"Heat (1995)", "No files found are eligible for import",
		"Inherent Vice (2014)", "Angie Tribeca (2 episodes)",
		"Free space for movies: 19.0 GB (/movies)",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// Dune is downloading, so it is not listed as still searched for.
	if strings.Count(out, "Dune (2021)") != 1 {
		t.Errorf("Dune listed twice:\n%s", out)
	}
	noKeyIn(t, l)
}

func TestMediaUsageErrors(t *testing.T) {
	l := mediaLab(t, &fakeArr{}, &fakeArr{tv: true})
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"media"}, "usage: anvil media"},
		{[]string{"media", "search"}, "needs a title"},
		{[]string{"media", "status", "dune"}, "takes no title"},
		{[]string{"media", "fly"}, `unknown command "fly"`},
	} {
		if code := l.run("", c.args...); code != 2 || !strings.Contains(l.err.String(), c.want) {
			t.Errorf("%v: exit %d, stderr %q", c.args, code, l.err.String())
		}
	}
}

func TestMediaEnvErrorIsShown(t *testing.T) {
	l := newTestLab(t)
	old := mediaEnv
	mediaEnv = func(*app) (mediaConfig, error) { return mediaConfig{}, errors.New("no site dict") }
	t.Cleanup(func() { mediaEnv = old })
	if code := l.run("", "media", "status"); code != 1 || !strings.Contains(l.err.String(), "anvil: media: no site dict") {
		t.Errorf("exit %d, stderr %q", code, l.err.String())
	}
}
