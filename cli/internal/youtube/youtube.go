// Package youtube is anvil youtube: follow YouTube channels and playlists with Pinchflat on
// the media VM, list them, and look for new videos now. Pinchflat has no API, so this drives
// its web forms (a CSRF token from the page, then the form post) on its direct lab address
// from scripts/youtube-env.sh. Pinchflat has no login of its own: the gateway's single
// sign-on guards its web page, and the port guard admits the operator's devices.
package youtube

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
)

func init() {
	app.Register(app.Command{Name: "youtube", Summary: "follow YouTube channels and playlists (Pinchflat)", Usage: usage, Run: cmdYoutube, Order: 51})
}

const usage = `usage: anvil youtube <command> [flags]

Pinchflat on the media VM downloads the channels and playlists it follows into the media
library's youtube folder as they publish. Jellyfin shows them as TV shows.

  add <url>                 follow a channel or playlist (its YouTube address)
      --name NAME           the name it is filed under (default: the channel's own)
      --profile NAME        the media profile (default: TV Shows, created on first use:
                            1080p, a folder per channel with seasons by year, subtitles,
                            artwork and NFO files for Jellyfin, no shorts or livestreams)
  list                      what is followed: downloaded and pending videos, profile
  refresh <name>            look for new videos now (Pinchflat also looks daily)
`

// profileName is the profile add uses unless --profile names another.
const profileName = "TV Shows"

// tvShows is Pinchflat's own "TV Shows" preset (its media profile form), which lays files
// out the way Jellyfin reads shows.
var tvShows = map[string]string{
	"name":                   profileName,
	"output_path_template":   "/shows/{{ source_custom_name }}/{{ season_by_year__episode_by_date_and_index }} - {{ title }}.{{ ext }}",
	"preferred_resolution":   "1080p",
	"shorts_behaviour":       "exclude",
	"livestream_behaviour":   "exclude",
	"download_subs":          "true",
	"embed_subs":             "true",
	"download_auto_subs":     "false",
	"sub_langs":              "en",
	"download_thumbnail":     "true",
	"embed_thumbnail":        "true",
	"download_metadata":      "true",
	"embed_metadata":         "true",
	"download_nfo":           "true",
	"download_source_images": "true",
	"redownload_delay_days":  "1",
	"sponsorblock_behaviour": "disabled",
}

// youtubeEnv returns Pinchflat's base URL. Tests replace it.
var youtubeEnv = func(a *app.App) (string, error) {
	root, err := repo.Root(a)
	if err != nil {
		return "", err
	}
	var out, errOut bytes.Buffer
	cmd := exec.Command("bash", "scripts/youtube-env.sh")
	cmd.Dir, cmd.Env = root, a.Env
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errOut.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", errors.New(msg)
	}
	var c struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(out.Bytes(), &c); err != nil || c.URL == "" {
		return "", fmt.Errorf("scripts/youtube-env.sh did not print the address")
	}
	return strings.TrimRight(c.URL, "/"), nil
}

type client struct {
	base string
	http *http.Client
}

func newClient(base string) *client {
	jar, _ := cookiejar.New(nil)
	return &client{base: base, http: &http.Client{
		Timeout: 30 * time.Second,
		Jar:     jar,
		// A form post answers with a redirect (success) or the form again (errors): read it.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func (c *client) get(path string) (string, error) {
	resp, err := c.http.Get(c.base + path)
	if err != nil {
		return "", fmt.Errorf("Pinchflat: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("Pinchflat: GET %s returned %d", path, resp.StatusCode)
	}
	return string(b), nil
}

var (
	csrfRE  = regexp.MustCompile(`<meta name="csrf-token" content="([^"]+)"`)
	errorRE = regexp.MustCompile(`(?s)<p class="[^"]*text-rose-600[^"]*">(.*?)</p>`)
	tagRE   = regexp.MustCompile(`<[^>]+>`)
)

// post sends a form from the page at formPath to path. It returns the redirect target, or
// the form's error messages as the error.
func (c *client) post(formPath, path string, fields url.Values) (string, error) {
	page, err := c.get(formPath)
	if err != nil {
		return "", err
	}
	m := csrfRE.FindStringSubmatch(page)
	if m == nil {
		return "", fmt.Errorf("Pinchflat: no form token on %s", formPath)
	}
	fields.Set("_csrf_token", html.UnescapeString(m[1]))
	resp, err := c.http.PostForm(c.base+path, fields)
	if err != nil {
		return "", fmt.Errorf("Pinchflat: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode/100 == 3 {
		return resp.Header.Get("Location"), nil
	}
	var msgs []string
	for _, e := range errorRE.FindAllStringSubmatch(string(b), -1) {
		t := strings.Join(strings.Fields(html.UnescapeString(tagRE.ReplaceAllString(e[1], " "))), " ")
		// Its banner over the form says only that there are errors below.
		if t != "" && !strings.HasPrefix(t, "Oops") {
			msgs = append(msgs, t)
		}
	}
	if len(msgs) > 0 {
		return "", errors.New(strings.Join(msgs, "; "))
	}
	return "", fmt.Errorf("Pinchflat: POST %s returned %d", path, resp.StatusCode)
}

var (
	selectRE = regexp.MustCompile(`(?s)<select[^>]*name="source\[media_profile_id\]"[^>]*>(.*?)</select>`)
	optionRE = regexp.MustCompile(`<option[^>]*value="(\d+)"[^>]*>([^<]*)`)
)

// profiles are the media profiles the source form offers: name -> id.
func (c *client) profiles() (map[string]string, error) {
	page, err := c.get("/sources/new")
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	if m := selectRE.FindStringSubmatch(page); m != nil {
		for _, o := range optionRE.FindAllStringSubmatch(m[1], -1) {
			out[strings.TrimSpace(html.UnescapeString(o[2]))] = o[1]
		}
	}
	return out, nil
}

// source is one row of the sources page.
type source struct {
	ID, Name, Profile   string
	Downloaded, Pending int
}

var (
	rowNameRE    = regexp.MustCompile(`(?s)href="/sources/(\d+)"[^>]*>\s*(.*?)\s*</a>`)
	rowCountRE   = regexp.MustCompile(`(?s)href="/sources/\d+/#tab-(pending|downloaded)"[^>]*>\s*<span[^>]*>\s*(\d+)\s*</span>`)
	rowProfileRE = regexp.MustCompile(`(?s)href="/media_profiles/\d+"[^>]*>\s*(.*?)\s*</a>`)
)

func (c *client) sources() ([]source, error) {
	page, err := c.get("/sources")
	if err != nil {
		return nil, err
	}
	var out []source
	for _, row := range strings.Split(page, "<tr")[1:] {
		m := rowNameRE.FindStringSubmatch(row)
		if m == nil {
			continue
		}
		s := source{ID: m[1], Name: html.UnescapeString(tagRE.ReplaceAllString(m[2], ""))}
		for _, n := range rowCountRE.FindAllStringSubmatch(row, -1) {
			v, _ := strconv.Atoi(n[2])
			if n[1] == "pending" {
				s.Pending = v
			} else {
				s.Downloaded = v
			}
		}
		if p := rowProfileRE.FindStringSubmatch(row); p != nil {
			s.Profile = html.UnescapeString(tagRE.ReplaceAllString(p[1], ""))
		}
		out = append(out, s)
	}
	return out, nil
}

type opts struct {
	name, profile string
}

func cmdYoutube(a *app.App, args []string) int {
	if len(args) == 0 {
		fmt.Fprint(a.Stderr, usage)
		return 2
	}
	sub, rest := args[0], args[1:]
	var o opts
	fs := flag.NewFlagSet("youtube "+sub, flag.ContinueOnError)
	switch sub {
	case "add":
		fs.StringVar(&o.name, "name", "", "")
		fs.StringVar(&o.profile, "profile", "", "")
	case "list", "refresh":
	case "help", "-h", "--help":
		fmt.Fprint(a.Stdout, usage)
		return 0
	default:
		fmt.Fprintf(a.Stderr, "anvil: youtube: unknown command %q\n%s", sub, usage)
		return 2
	}
	pos, code, ok := a.Flags(fs, usage, interleave(rest))
	if !ok {
		return code
	}
	arg := strings.TrimSpace(strings.Join(pos, " "))
	switch {
	case sub == "add" && arg == "":
		fmt.Fprintln(a.Stderr, "anvil: youtube add needs a channel or playlist address")
		return 2
	case sub == "refresh" && arg == "":
		fmt.Fprintln(a.Stderr, "anvil: youtube refresh needs a name (anvil youtube list shows them)")
		return 2
	case sub == "list" && arg != "":
		fmt.Fprintln(a.Stderr, "anvil: youtube list takes no argument")
		return 2
	}

	base, err := youtubeEnv(a)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
		return 1
	}
	c := newClient(base)
	switch sub {
	case "add":
		return add(a, c, arg, o)
	case "list":
		return list(a, c)
	default:
		return refresh(a, c, arg)
	}
}

// interleave puts flags before the arguments, so `add <url> --name X` works too.
func interleave(args []string) []string {
	var flags, words []string
	for i := 0; i < len(args); i++ {
		s := args[i]
		if strings.HasPrefix(s, "-") {
			flags = append(flags, s)
			if !strings.Contains(s, "=") && (s == "--name" || s == "-name" || s == "--profile" || s == "-profile") && i+1 < len(args) {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		words = append(words, s)
	}
	return append(flags, words...)
}

func youtubeURL(s string) bool {
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return false
	}
	h := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	return h == "youtube.com" || h == "m.youtube.com" || h == "youtu.be" || h == "music.youtube.com"
}

func add(a *app.App, c *client, link string, o opts) int {
	if !youtubeURL(link) {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %q is not a YouTube address (https://www.youtube.com/@channel or a playlist)\n", link)
		return 2
	}
	profiles, err := c.profiles()
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
		return 1
	}
	want := o.profile
	if want == "" {
		want = profileName
	}
	id, ok := profiles[want]
	if !ok && o.profile != "" {
		names := make([]string, 0, len(profiles))
		for n := range profiles {
			names = append(names, n)
		}
		fmt.Fprintf(a.Stderr, "anvil: youtube: no media profile %q (there are: %s)\n", want, strings.Join(names, ", "))
		return 2
	}
	if !ok {
		fields := url.Values{}
		for k, v := range tvShows {
			fields.Set("media_profile["+k+"]", v)
		}
		if _, err := c.post("/media_profiles/new", "/media_profiles", fields); err != nil {
			fmt.Fprintf(a.Stderr, "anvil: youtube: creating the %s profile: %v\n", profileName, err)
			return 1
		}
		fmt.Fprintf(a.Stdout, "Created the media profile %s (1080p, Jellyfin layout).\n", profileName)
		if profiles, err = c.profiles(); err != nil {
			fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
			return 1
		}
		if id, ok = profiles[profileName]; !ok {
			fmt.Fprintf(a.Stderr, "anvil: youtube: the %s profile is not offered after creating it\n", profileName)
			return 1
		}
	}
	fields := url.Values{
		"source[original_url]":     {link},
		"source[media_profile_id]": {id},
		"source[download_media]":   {"true"},
	}
	if o.name != "" {
		fields.Set("source[custom_name]", o.name)
	}
	loc, err := c.post("/sources/new", "/sources", fields)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
		return 1
	}
	label := o.name
	if label == "" {
		label = link
	}
	fmt.Fprintf(a.Stdout, "Following %s (%s). Pinchflat is indexing it now and downloads new videos as they come.\n", label, want)
	if strings.HasPrefix(loc, "/sources/") {
		fmt.Fprintln(a.Stdout, "Follow it with: anvil youtube list")
	}
	return 0
}

func list(a *app.App, c *client) int {
	ss, err := c.sources()
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
		return 1
	}
	if len(ss) == 0 {
		fmt.Fprintln(a.Stdout, "Nothing is followed yet. Add a channel: anvil youtube add https://www.youtube.com/@channel")
		return 0
	}
	w := 4
	for _, s := range ss {
		if l := len([]rune(s.Name)); l > w {
			w = l
		}
	}
	fmt.Fprintf(a.Stdout, "%-*s  %10s  %7s  %s\n", w, "NAME", "DOWNLOADED", "PENDING", "PROFILE")
	for _, s := range ss {
		fmt.Fprintf(a.Stdout, "%-*s  %10d  %7d  %s\n", w, s.Name, s.Downloaded, s.Pending, s.Profile)
	}
	return 0
}

func refresh(a *app.App, c *client, name string) int {
	ss, err := c.sources()
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
		return 1
	}
	var hits []source
	for _, s := range ss {
		if strings.EqualFold(s.Name, name) {
			hits = []source{s}
			break
		}
		if strings.Contains(strings.ToLower(s.Name), strings.ToLower(name)) {
			hits = append(hits, s)
		}
	}
	switch len(hits) {
	case 0:
		fmt.Fprintf(a.Stderr, "anvil: youtube: nothing followed matches %q (anvil youtube list shows them)\n", name)
		return 1
	case 1:
	default:
		names := make([]string, len(hits))
		for i, s := range hits {
			names[i] = s.Name
		}
		fmt.Fprintf(a.Stderr, "anvil: youtube: %q matches %s: be more precise\n", name, strings.Join(names, ", "))
		return 2
	}
	s := hits[0]
	if _, err := c.post("/sources/"+s.ID, "/sources/"+s.ID+"/force_index", url.Values{}); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: youtube: %v\n", err)
		return 1
	}
	fmt.Fprintf(a.Stdout, "Pinchflat is looking for new videos on %s now. New ones download on their own.\n", s.Name)
	return 0
}
