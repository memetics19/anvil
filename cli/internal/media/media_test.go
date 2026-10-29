package media

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/testlab"
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
	profiles string // JSON array for qualityprofile; empty: Any, HD-1080p, Ultra-HD
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
		if r.Method == http.MethodPost || r.Method == http.MethodPut {
			var body map[string]any
			b, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(b, &body)
			f.mu.Lock()
			f.posts[p] = append(f.posts[p], body)
			f.mu.Unlock()
		}
		if r.Method == http.MethodPost {
			if f.addError != 0 && (p == "movie" || p == "series") {
				w.WriteHeader(f.addError)
				_, _ = io.WriteString(w, `[{"errorMessage":"This movie has already been added"}]`)
				return
			}
			w.WriteHeader(http.StatusCreated)
			if p == "series" || p == "movie" {
				_, _ = io.WriteString(w, `{"id":42}`)
			} else {
				_, _ = io.WriteString(w, `{}`)
			}
			return
		}
		if r.Method == http.MethodPut {
			_, _ = io.WriteString(w, `{}`)
			return
		}
		switch {
		case strings.HasSuffix(p, "/lookup"):
			_, _ = io.WriteString(w, f.lookup)
		case p == "episode":
			_, _ = io.WriteString(w, `[{"id":101,"seasonNumber":1},{"id":102,"seasonNumber":1},{"id":201,"seasonNumber":2}]`)
		case p == "qualityprofile":
			if f.profiles != "" {
				_, _ = io.WriteString(w, f.profiles)
				break
			}
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
func mediaLab(t *testing.T, radarr, sonarr *fakeArr) *testlab.Lab {
	t.Helper()
	l := testlab.New(t)
	rs, ss := radarr.server(t), sonarr.server(t)
	old := mediaEnv
	mediaEnv = func(*app.App) (mediaConfig, error) {
		return mediaConfig{Radarr: arrEndpoint{rs.URL, testArrSentinel}, Sonarr: arrEndpoint{ss.URL, testArrSentinel}}, nil
	}
	t.Cleanup(func() { mediaEnv = old })
	return l
}

func noKeyIn(t *testing.T, l *testlab.Lab) {
	t.Helper()
	if strings.Contains(l.Out.String()+l.Err.String(), testArrSentinel) {
		t.Fatalf("the API key reached the output:\n%s%s", l.Out.String(), l.Err.String())
	}
}

func TestMediaSearchListsMatches(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Dune","year":2021,"overview":"x"},{"title":"Dune","year":1984,"id":7,"hasFile":true}]`}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "search", "dune"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	out := l.Out.String()
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
	if code := l.Run("1\n", "media", "get", "dune"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
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
	if !strings.Contains(l.Out.String(), "Which one? [1-2]") || !strings.Contains(l.Out.String(), "Added Dune (2021) (HD-1080p") {
		t.Errorf("output:\n%s", l.Out.String())
	}
	noKeyIn(t, l)
}

func TestMediaGetPrefersThePolicyProfile(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30,
		profiles: `[{"id":1,"name":"Any"},{"id":4,"name":"HD-1080p"},{"id":7,"name":"1080p+"}]`}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "get", "dune", "--pick", "1"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	if got := radarr.posts["movie"][0]; got["qualityProfileId"] != float64(7) {
		t.Errorf("add body = %v, want profile 1080p+ (7)", got)
	}
	if !strings.Contains(l.Out.String(), "(1080p+") {
		t.Errorf("output:\n%s", l.Out.String())
	}
}

func TestMediaGetPickAndQuality(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "get", "dune", "--pick", "2", "--quality", "ultra-hd"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	got := radarr.posts["movie"][0]
	if got["tmdbId"] != float64(841) || got["qualityProfileId"] != float64(5) {
		t.Errorf("add body = %v", got)
	}
	if strings.Contains(l.Out.String(), "Which one?") {
		t.Error("--pick still asked")
	}
}

func TestMediaGetUnknownQualityNamesTheProfiles(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "get", "dune", "--pick", "1", "--quality", "4K"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.Contains(l.Err.String(), `no quality profile "4K" (it has: Any, HD-1080p, Ultra-HD)`) {
		t.Errorf("stderr: %s", l.Err.String())
	}
	if len(radarr.posts["movie"]) != 0 {
		t.Error("added despite the unknown profile")
	}
}

func TestMediaGetNoAnswerAddsNothing(t *testing.T) {
	radarr := &fakeArr{lookup: twoMovies, free: 200 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "get", "dune"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if len(radarr.posts["movie"]) != 0 || !strings.Contains(l.Out.String(), "Nothing added.") {
		t.Errorf("posts %v, output:\n%s", radarr.posts, l.Out.String())
	}
}

func TestMediaGetLowSpaceAsks(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Dune","year":2021,"tmdbId":1}]`, free: 3 << 30}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("n\n", "media", "get", "dune"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if len(radarr.posts["movie"]) != 0 || !strings.Contains(l.Out.String(), "Only 3.0 GB free in /movies.") {
		t.Errorf("output:\n%s", l.Out.String())
	}
	if code := l.Run("", "media", "get", "dune", "--yes"); code != 0 {
		t.Fatalf("--yes: exit %d: %s", code, l.Err.String())
	}
	if len(radarr.posts["movie"]) != 1 {
		t.Error("--yes did not add")
	}
}

func TestMediaGetExistingSearchesAgain(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Inherent Vice","year":2014,"id":12,"hasFile":false}]`}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "get", "inherent vice"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
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
	if code := l.Run("", "media", "get", "the", "expanse", "--tv"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	got := sonarr.posts["series"][0]
	opts, _ := got["addOptions"].(map[string]any)
	if got["tvdbId"] != float64(280619) || got["rootFolderPath"] != "/tv" || got["seasonFolder"] != true ||
		opts["searchForMissingEpisodes"] != true || opts["monitor"] != "all" {
		t.Errorf("add body = %v", got)
	}
}

func TestMediaGetSeriesSeason(t *testing.T) {
	seasons := `"seasons":[{"seasonNumber":0},{"seasonNumber":1},{"seasonNumber":2}]`
	lookup := `[{"title":"The Expanse","year":2015,"tvdbId":280619,` + seasons + `}]`

	// --season 1: add monitoring only season 1, then monitor and search its episodes.
	sonarr := &fakeArr{tv: true, lookup: lookup, free: 200 << 30}
	l := mediaLab(t, &fakeArr{}, sonarr)
	if code := l.Run("", "media", "get", "the", "expanse", "--tv", "--season", "1"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	got := sonarr.posts["series"][0]
	opts, _ := got["addOptions"].(map[string]any)
	if opts["monitor"] != "none" || opts["searchForMissingEpisodes"] != false {
		t.Errorf("addOptions = %v", opts)
	}
	mon := map[int]bool{}
	for _, s := range got["seasons"].([]any) {
		m := s.(map[string]any)
		mon[int(m["seasonNumber"].(float64))] = m["monitored"].(bool)
	}
	if mon[1] != true || mon[2] != false || mon[0] != false {
		t.Errorf("season monitoring = %v", mon)
	}
	put := sonarr.posts["episode/monitor"][0]
	ids, _ := put["episodeIds"].([]any)
	if len(ids) != 2 || ids[0] != float64(101) || put["monitored"] != true {
		t.Errorf("episode/monitor = %v", put)
	}
	cmd := sonarr.posts["command"][0]
	if cmd["name"] != "SeasonSearch" || cmd["seasonNumber"] != float64(1) || cmd["seriesId"] != float64(42) {
		t.Errorf("command = %v", cmd)
	}

	// A season the series does not have is refused, and nothing is added.
	sonarr2 := &fakeArr{tv: true, lookup: lookup, free: 200 << 30}
	l2 := mediaLab(t, &fakeArr{}, sonarr2)
	if code := l2.Run("", "media", "get", "the", "expanse", "--tv", "--season", "9"); code != 1 {
		t.Fatalf("season 9: exit %d, want 1", code)
	}
	if len(sonarr2.posts["series"]) != 0 {
		t.Errorf("added despite a bad season: %v", sonarr2.posts["series"])
	}

	// At the prompt, "all" gets every season (monitor all, no per-season search).
	sonarr3 := &fakeArr{tv: true, lookup: lookup, free: 200 << 30}
	l3 := mediaLab(t, &fakeArr{}, sonarr3)
	if code := l3.Run("all\n", "media", "get", "the", "expanse", "--tv"); code != 0 {
		t.Fatalf("all: exit %d: %s", code, l3.Err.String())
	}
	if o, _ := sonarr3.posts["series"][0]["addOptions"].(map[string]any); o["monitor"] != "all" {
		t.Errorf("all: addOptions = %v", o)
	}
	if len(sonarr3.posts["command"]) != 0 {
		t.Errorf("all should not season-search: %v", sonarr3.posts["command"])
	}

	// At the prompt, a season number gets that season.
	sonarr4 := &fakeArr{tv: true, lookup: lookup, free: 200 << 30}
	l4 := mediaLab(t, &fakeArr{}, sonarr4)
	if code := l4.Run("2\n", "media", "get", "the", "expanse", "--tv"); code != 0 {
		t.Fatalf("season 2: exit %d: %s", code, l4.Err.String())
	}
	if sonarr4.posts["command"][0]["seasonNumber"] != float64(2) {
		t.Errorf("prompt season = %v", sonarr4.posts["command"][0])
	}
}

func TestMediaGetShowsArrError(t *testing.T) {
	radarr := &fakeArr{lookup: `[{"title":"Dune","year":2021,"tmdbId":1}]`, free: 200 << 30, addError: 400}
	l := mediaLab(t, radarr, &fakeArr{tv: true})
	if code := l.Run("", "media", "get", "dune"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.Contains(l.Err.String(), "This movie has already been added") {
		t.Errorf("stderr: %s", l.Err.String())
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
	if code := l.Run("", "media", "status"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	out := l.Out.String()
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
		if code := l.Run("", c.args...); code != 2 || !strings.Contains(l.Err.String(), c.want) {
			t.Errorf("%v: exit %d, stderr %q", c.args, code, l.Err.String())
		}
	}
}

func TestMediaEnvErrorIsShown(t *testing.T) {
	l := testlab.New(t)
	old := mediaEnv
	mediaEnv = func(*app.App) (mediaConfig, error) { return mediaConfig{}, errors.New("no site dict") }
	t.Cleanup(func() { mediaEnv = old })
	if code := l.Run("", "media", "status"); code != 1 || !strings.Contains(l.Err.String(), "anvil: media: no site dict") {
		t.Errorf("exit %d, stderr %q", code, l.Err.String())
	}
}

func TestMediaVaultUnreachableHint(t *testing.T) {
	l := testlab.New(t)
	old := mediaEnv
	mediaEnv = func(*app.App) (mediaConfig, error) {
		return mediaConfig{}, errors.New("site-source: cannot read kv/homelab/site: Vault (Keychain vault-ip) is unreachable or returned an error.")
	}
	t.Cleanup(func() { mediaEnv = old })
	if code := l.Run("", "media", "status"); code != 1 || !strings.Contains(l.Err.String(), "Vault must answer: be at home or on the VPN") {
		t.Errorf("exit %d, stderr %q", code, l.Err.String())
	}
}
