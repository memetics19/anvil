package youtube

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/testlab"
)

// fakePinchflat answers the pages and form posts anvil youtube uses, in Pinchflat's markup.
type fakePinchflat struct {
	mu       sync.Mutex
	profiles map[string]string // id -> name
	sources  string            // the rows of the sources table
	posts    map[string][]url.Values
	badURL   bool // a source post fails like an address yt-dlp cannot read
}

const page = `<html><head><meta name="csrf-token" content="tok&amp;en"></head><body>%s</body></html>`

func (f *fakePinchflat) server(t *testing.T) *httptest.Server {
	t.Helper()
	f.posts = map[string][]url.Values{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if r.Method == http.MethodPost {
			_ = r.ParseForm()
			if r.PostForm.Get("_csrf_token") != "tok&en" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			f.posts[r.URL.Path] = append(f.posts[r.URL.Path], r.PostForm)
			switch r.URL.Path {
			case "/media_profiles":
				f.profiles["7"] = r.PostForm.Get("media_profile[name]")
				w.Header().Set("Location", "/media_profiles/7")
			case "/sources":
				if f.badURL {
					_, _ = io.WriteString(w, strings.Replace(page, "%s", `<p class="mt-1 mb-5 flex gap-3 text-md leading-6 text-rose-600 phx-no-feedback:hidden"><span class="hero"></span> Oops, something went wrong! Please check the errors below.</p><p class="mt-1 mb-5 flex gap-3 text-md leading-6 text-rose-600 phx-no-feedback:hidden"><span class="hero"></span>could not fetch source details from URL</p>`, 1))
					return
				}
				w.Header().Set("Location", "/sources/12")
			default:
				w.Header().Set("Location", strings.TrimSuffix(r.URL.Path, "/force_index"))
			}
			w.WriteHeader(http.StatusFound)
			return
		}
		switch r.URL.Path {
		case "/sources/new":
			opts := ""
			for id, n := range f.profiles {
				opts += `<option value="` + id + `">` + n + `</option>`
			}
			_, _ = io.WriteString(w, strings.Replace(page, "%s", `<select id="x" name="source[media_profile_id]" class="y"><option value="">Select</option>`+opts+`</select>`, 1))
		case "/media_profiles/new", "/sources/3", "/sources/4":
			_, _ = io.WriteString(w, strings.Replace(page, "%s", "<form></form>", 1))
		case "/sources":
			_, _ = io.WriteString(w, strings.Replace(page, "%s", "<table><tbody>"+f.sources+"</tbody></table>", 1))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func row(id, name, pending, downloaded, profile string) string {
	return `<tr id="r` + id + `"><td><a href="/sources/` + id + `" class="underline">
          ` + name + `
        </a></td><td><a href="/sources/` + id + `/#tab-pending" class="u"><span x-data x-text="Intl.NumberFormat().format(` + pending + `)">` + pending + `</span></a></td><td><a href="/sources/` + id + `/#tab-downloaded" class="u"><span x-data>` + downloaded + `</span></a></td><td><span class="text-lg">∞</span></td><td><a href="/media_profiles/2" class="u">` + profile + `</a></td></tr>`
}

func lab(t *testing.T, f *fakePinchflat) *testlab.Lab {
	t.Helper()
	l := testlab.New(t)
	srv := f.server(t)
	old := youtubeEnv
	youtubeEnv = func(*app.App) (string, error) { return srv.URL, nil }
	t.Cleanup(func() { youtubeEnv = old })
	return l
}

func TestAddCreatesTheProfileOnceThenTheSource(t *testing.T) {
	f := &fakePinchflat{profiles: map[string]string{"1": "Default"}}
	l := lab(t, f)
	if code := l.Run("", "youtube", "add", "https://www.youtube.com/@somechannel", "--name", "Some Channel"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	mp := f.posts["/media_profiles"]
	if len(mp) != 1 || mp[0].Get("media_profile[name]") != "TV Shows" || mp[0].Get("media_profile[preferred_resolution]") != "1080p" ||
		mp[0].Get("media_profile[shorts_behaviour]") != "exclude" || mp[0].Get("media_profile[download_nfo]") != "true" ||
		!strings.HasPrefix(mp[0].Get("media_profile[output_path_template]"), "/shows/{{ source_custom_name }}/") {
		t.Errorf("profile posts = %v", mp)
	}
	src := f.posts["/sources"]
	if len(src) != 1 || src[0].Get("source[original_url]") != "https://www.youtube.com/@somechannel" ||
		src[0].Get("source[media_profile_id]") != "7" || src[0].Get("source[custom_name]") != "Some Channel" {
		t.Errorf("source posts = %v", src)
	}
	if out := l.Out.String(); !strings.Contains(out, "Created the media profile TV Shows") || !strings.Contains(out, "Following Some Channel (TV Shows)") {
		t.Errorf("output:\n%s", out)
	}
	// A second add reuses the profile.
	if code := l.Run("", "youtube", "add", "https://youtube.com/playlist?list=PL1"); code != 0 {
		t.Fatalf("second add: exit %d: %s", code, l.Err.String())
	}
	if len(f.posts["/media_profiles"]) != 1 || f.posts["/sources"][1].Get("source[media_profile_id]") != "7" || f.posts["/sources"][1].Has("source[custom_name]") {
		t.Errorf("second add: profiles %v, sources %v", f.posts["/media_profiles"], f.posts["/sources"])
	}
}

func TestAddShowsPinchflatsReason(t *testing.T) {
	f := &fakePinchflat{profiles: map[string]string{"2": "TV Shows"}, badURL: true}
	l := lab(t, f)
	code := l.Run("", "youtube", "add", "https://www.youtube.com/@missing")
	if code != 1 || l.Err.String() != "anvil: youtube: could not fetch source details from URL\n" {
		t.Errorf("exit %d, stderr %q", code, l.Err.String())
	}
}

func TestAddRefusesOtherSitesAndUnknownProfiles(t *testing.T) {
	f := &fakePinchflat{profiles: map[string]string{"2": "TV Shows"}}
	l := lab(t, f)
	if code := l.Run("", "youtube", "add", "https://example.com/@x"); code != 2 || !strings.Contains(l.Err.String(), "is not a YouTube address") {
		t.Errorf("other site: exit %d, %q", code, l.Err.String())
	}
	if code := l.Run("", "youtube", "add", "https://www.youtube.com/@x", "--profile", "4K"); code != 2 || !strings.Contains(l.Err.String(), `no media profile "4K" (there are: TV Shows)`) {
		t.Errorf("unknown profile: exit %d, %q", code, l.Err.String())
	}
	if len(f.posts) != 0 {
		t.Errorf("posted: %v", f.posts)
	}
}

func TestListAndRefresh(t *testing.T) {
	f := &fakePinchflat{profiles: map[string]string{"2": "TV Shows"},
		sources: row("3", "Kurzgesagt &amp; Friends", "4", "120", "TV Shows") + row("4", "Veritasium", "0", "1234", "TV Shows")}
	l := lab(t, f)
	if code := l.Run("", "youtube", "list"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	out := l.Out.String()
	for _, want := range []string{"NAME                  DOWNLOADED  PENDING  PROFILE", "Kurzgesagt & Friends         120        4  TV Shows", "Veritasium                  1234        0  TV Shows"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if code := l.Run("", "youtube", "refresh", "veritas"); code != 0 || !strings.Contains(l.Out.String(), "looking for new videos on Veritasium") {
		t.Errorf("refresh: exit %d, %s%s", code, l.Out.String(), l.Err.String())
	}
	if len(f.posts["/sources/4/force_index"]) != 1 {
		t.Errorf("force_index posts = %v", f.posts)
	}
	if code := l.Run("", "youtube", "refresh", "nothing"); code != 1 || !strings.Contains(l.Err.String(), `nothing followed matches "nothing"`) {
		t.Errorf("no match: exit %d, %q", code, l.Err.String())
	}
	if code := l.Run("", "youtube", "refresh", "i"); code != 2 || !strings.Contains(l.Err.String(), "be more precise") {
		t.Errorf("ambiguous: exit %d, %q", code, l.Err.String())
	}
}

func TestUsageErrors(t *testing.T) {
	l := lab(t, &fakePinchflat{profiles: map[string]string{}})
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"youtube"}, "usage: anvil youtube"},
		{[]string{"youtube", "add"}, "needs a channel or playlist address"},
		{[]string{"youtube", "refresh"}, "needs a name"},
		{[]string{"youtube", "list", "x"}, "takes no argument"},
		{[]string{"youtube", "fly"}, `unknown command "fly"`},
	} {
		if code := l.Run("", c.args...); code != 2 || !strings.Contains(l.Err.String(), c.want) {
			t.Errorf("%v: exit %d, stderr %q", c.args, code, l.Err.String())
		}
	}
}
