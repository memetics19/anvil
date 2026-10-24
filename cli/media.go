package main

// anvil media: find a movie or a series, add it so Radarr or Sonarr downloads it, and
// follow the downloads. The addresses and API keys come from scripts/media-env.sh (site
// dict and Vault) through a pipe. They are never printed.

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

func init() {
	register(command{"media", "search, download and follow movies and series (Radarr, Sonarr)", mediaUsage, cmdMedia, 50})
}

const mediaUsage = `usage: anvil media <command> [flags]

Movies go through Radarr, series (--tv) through Sonarr. Both search the indexers and hand
the download to qBittorrent. The addresses and API keys come from Vault
(scripts/media-env.sh) and are never printed.

  search <title> [--tv]       list what matches, and what is already in the library
  get <title> [--tv]          add it and start the download. Asks which one when several
                              match.
      --pick N                take match N of the list without asking
      --quality NAME          quality profile (default HD-1080p, else the first one)
      --yes                   do not ask before adding when the disk is nearly full
  status [--watch]            downloads in progress, what is still searched for, and the
                              free space. --watch refreshes every 10 seconds.
`

// mediaLowSpace is the free space under which get asks before adding.
const mediaLowSpace = 15 << 30

type arrEndpoint struct {
	URL string `json:"url"`
	Key string `json:"key"`
}

type mediaConfig struct {
	Radarr arrEndpoint `json:"radarr"`
	Sonarr arrEndpoint `json:"sonarr"`
}

// mediaEnv returns the endpoints. Tests replace it.
var mediaEnv = func(a *app) (mediaConfig, error) {
	root, err := a.repoRoot()
	if err != nil {
		return mediaConfig{}, err
	}
	var out, errOut bytes.Buffer
	cmd := exec.Command("bash", "scripts/media-env.sh")
	cmd.Dir, cmd.Env = root, a.env
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		// stderr carries only reasons (env.sh warnings, media-env's own), never a key: the
		// keys go to stdout only.
		msg := strings.TrimSpace(errOut.String())
		if msg == "" {
			msg = err.Error()
		}
		return mediaConfig{}, errors.New(msg)
	}
	var c mediaConfig
	if err := json.Unmarshal(out.Bytes(), &c); err != nil {
		return mediaConfig{}, fmt.Errorf("scripts/media-env.sh did not print the endpoints: %v", err)
	}
	return c, nil
}

// arr is one Radarr or Sonarr instance.
type arr struct {
	ep     arrEndpoint
	client *http.Client
	tv     bool
}

func (c arr) name() string {
	if c.tv {
		return "Sonarr"
	}
	return "Radarr"
}

// kind is the API's word for the library items: movie or series.
func (c arr) kind() string {
	if c.tv {
		return "series"
	}
	return "movie"
}

func (c arr) do(method, path string, body, into any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, strings.TrimRight(c.ep.URL, "/")+"/api/v3/"+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("X-Api-Key", c.ep.Key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		// The URL holds no key: the key is only in the header.
		return fmt.Errorf("%s: %v", c.name(), err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s: %s %s returned %d: %s", c.name(), method, strings.SplitN(path, "?", 2)[0], resp.StatusCode, arrError(data))
	}
	if into != nil {
		if err := json.Unmarshal(data, into); err != nil {
			return fmt.Errorf("%s: unexpected answer to %s: %v", c.name(), path, err)
		}
	}
	return nil
}

// arrError picks the readable message out of an error answer.
func arrError(data []byte) string {
	var list []struct {
		ErrorMessage string `json:"errorMessage"`
	}
	if json.Unmarshal(data, &list) == nil && len(list) > 0 && list[0].ErrorMessage != "" {
		return list[0].ErrorMessage
	}
	var one struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(data, &one) == nil && one.Message != "" {
		return one.Message
	}
	s := strings.TrimSpace(string(data))
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

// item is a lookup result. Raw keeps the whole object, which is what the add call takes.
type item struct {
	Title    string `json:"title"`
	Year     int    `json:"year"`
	ID       int    `json:"id"`
	Overview string `json:"overview"`
	HasFile  bool   `json:"hasFile"`
	Network  string `json:"network"`
	Seasons  []any  `json:"seasons"`
	Stats    *struct {
		EpisodeFileCount int `json:"episodeFileCount"`
		EpisodeCount     int `json:"episodeCount"`
	} `json:"statistics"`
	Raw map[string]any `json:"-"`
}

func (c arr) lookup(term string) ([]item, error) {
	var raw []map[string]any
	if err := c.do("GET", c.kind()+"/lookup?term="+url.QueryEscape(term), nil, &raw); err != nil {
		return nil, err
	}
	items := make([]item, 0, len(raw))
	for _, r := range raw {
		b, _ := json.Marshal(r)
		var it item
		_ = json.Unmarshal(b, &it)
		it.Raw = r
		items = append(items, it)
	}
	return items, nil
}

func (it item) label() string {
	if it.Year > 0 {
		return fmt.Sprintf("%s (%d)", it.Title, it.Year)
	}
	return it.Title
}

func (c arr) state(it item) string {
	switch {
	case it.ID == 0:
		return ""
	case !c.tv && it.HasFile:
		return "in the library"
	case !c.tv:
		return "added, no file yet"
	case it.Stats != nil && it.Stats.EpisodeCount > 0:
		return fmt.Sprintf("in the library, %d/%d episodes", it.Stats.EpisodeFileCount, it.Stats.EpisodeCount)
	default:
		return "in the library"
	}
}

type mediaOpts struct {
	tv, yes, watch bool
	pick           int
	quality        string
}

func cmdMedia(a *app, args []string) int {
	if len(args) == 0 {
		fmt.Fprint(a.stderr, mediaUsage)
		return 2
	}
	sub, rest := args[0], args[1:]
	var o mediaOpts
	fs := flag.NewFlagSet("media "+sub, flag.ContinueOnError)
	switch sub {
	case "search":
		fs.BoolVar(&o.tv, "tv", false, "")
	case "get":
		fs.BoolVar(&o.tv, "tv", false, "")
		fs.BoolVar(&o.yes, "yes", false, "")
		fs.IntVar(&o.pick, "pick", 0, "")
		fs.StringVar(&o.quality, "quality", "", "")
	case "status":
		fs.BoolVar(&o.watch, "watch", false, "")
	case "help", "-h", "--help":
		fmt.Fprint(a.stdout, mediaUsage)
		return 0
	default:
		fmt.Fprintf(a.stderr, "anvil: media: unknown command %q\n%s", sub, mediaUsage)
		return 2
	}
	pos, code, ok := a.flags(fs, mediaUsage, interleave(rest))
	if !ok {
		return code
	}
	term := strings.TrimSpace(strings.Join(pos, " "))
	if sub != "status" && term == "" {
		fmt.Fprintf(a.stderr, "anvil: media %s needs a title\n", sub)
		return 2
	}
	if sub == "status" && term != "" {
		fmt.Fprintln(a.stderr, "anvil: media status takes no title")
		return 2
	}

	cfg, err := mediaEnv(a)
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
		if msg := err.Error(); strings.Contains(msg, "Vault") && strings.Contains(msg, "unreachable") {
			fmt.Fprintln(a.stderr, "anvil media reads the API keys from Vault, so Vault must answer: be at home or on the VPN\n"+
				"(docs/cli.md, No route to host on macOS, also covers a lab alias left on the Wi-Fi).")
		}
		return 1
	}
	client := &http.Client{Timeout: 30 * time.Second}
	radarr := arr{ep: cfg.Radarr, client: client}
	sonarr := arr{ep: cfg.Sonarr, client: client, tv: true}
	c := radarr
	if o.tv {
		c = sonarr
	}
	switch sub {
	case "search":
		return mediaSearch(a, c, term)
	case "get":
		return mediaGet(a, c, term, o)
	default:
		return mediaStatus(a, radarr, sonarr, o.watch)
	}
}

// interleave puts flags before the title, so `get dune --tv` works like `get --tv dune`.
func interleave(args []string) []string {
	var flags, words []string
	for i := 0; i < len(args); i++ {
		s := args[i]
		if strings.HasPrefix(s, "-") {
			flags = append(flags, s)
			if (s == "--pick" || s == "-pick" || s == "--quality" || s == "-quality") && i+1 < len(args) {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		words = append(words, s)
	}
	return append(flags, words...)
}

const mediaListMax = 10

func mediaList(a *app, c arr, items []item) {
	for i, it := range items {
		if i == mediaListMax {
			fmt.Fprintf(a.stdout, "  ... %d more: make the title more precise\n", len(items)-mediaListMax)
			break
		}
		extra := c.state(it)
		if extra != "" {
			extra = "  [" + extra + "]"
		}
		fmt.Fprintf(a.stdout, "%3d. %s%s\n", i+1, it.label(), extra)
		if ov := oneLine(it.Overview, 100); ov != "" {
			fmt.Fprintf(a.stdout, "     %s\n", ov)
		}
	}
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		s = string(r[:max-1]) + "…"
	}
	return s
}

func mediaSearch(a *app, c arr, term string) int {
	items, err := c.lookup(term)
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
		return 1
	}
	if len(items) == 0 {
		fmt.Fprintf(a.stdout, "No %s matches %q.\n", c.kind(), term)
		return 0
	}
	mediaList(a, c, items)
	return 0
}

func mediaGet(a *app, c arr, term string, o mediaOpts) int {
	items, err := c.lookup(term)
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
		return 1
	}
	if len(items) == 0 {
		fmt.Fprintf(a.stdout, "No %s matches %q.\n", c.kind(), term)
		return 1
	}
	if len(items) > mediaListMax {
		items = items[:mediaListMax]
	}
	choice := o.pick
	switch {
	case choice > 0:
		if choice > len(items) {
			fmt.Fprintf(a.stderr, "anvil: media: --pick %d, but there are %d matches\n", choice, len(items))
			return 2
		}
	case len(items) == 1:
		choice = 1
	default:
		mediaList(a, c, items)
		fmt.Fprintf(a.stdout, "Which one? [1-%d] ", len(items))
		ans, ok := readLine(a.stdin)
		n, err := strconv.Atoi(ans)
		if !ok || err != nil || n < 1 || n > len(items) {
			fmt.Fprintln(a.stdout, "\nNothing added.")
			return 1
		}
		choice = n
	}
	it := items[choice-1]

	// Already in the library: search again instead of adding twice.
	if it.ID > 0 {
		if !c.tv && it.HasFile {
			fmt.Fprintf(a.stdout, "%s is already in the library.\n", it.label())
			return 0
		}
		cmd := map[string]any{"name": "MoviesSearch", "movieIds": []int{it.ID}}
		if c.tv {
			cmd = map[string]any{"name": "SeriesSearch", "seriesId": it.ID}
		}
		if err := c.do("POST", "command", cmd, nil); err != nil {
			fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
			return 1
		}
		fmt.Fprintf(a.stdout, "%s is already added: %s searches for it again. Follow it with: anvil media status\n", it.label(), c.name())
		return 0
	}

	profileID, profileName, err := c.profile(o.quality)
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
		return 1
	}
	root, free, err := c.rootFolder()
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
		return 1
	}
	if free < mediaLowSpace && !o.yes {
		fmt.Fprintf(a.stdout, "Only %s free in %s.\n", human(free), root)
		if !askYesNo(a.stdin, a.stdout, "Add it anyway?") {
			fmt.Fprintln(a.stdout, "Nothing added.")
			return 1
		}
	}

	body := it.Raw
	body["qualityProfileId"] = profileID
	body["rootFolderPath"] = root
	body["monitored"] = true
	if c.tv {
		body["seasonFolder"] = true
		body["addOptions"] = map[string]any{"monitor": "all", "searchForMissingEpisodes": true}
	} else {
		body["minimumAvailability"] = "released"
		body["addOptions"] = map[string]any{"searchForMovie": true}
	}
	if err := c.do("POST", c.kind(), body, nil); err != nil {
		fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
		return 1
	}
	fmt.Fprintf(a.stdout, "Added %s (%s, %s free). %s is searching for it now.\nFollow it with: anvil media status\n",
		it.label(), profileName, human(free), c.name())
	return 0
}

func (c arr) profile(want string) (int, string, error) {
	var ps []struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}
	if err := c.do("GET", "qualityprofile", nil, &ps); err != nil {
		return 0, "", err
	}
	if len(ps) == 0 {
		return 0, "", fmt.Errorf("%s has no quality profile", c.name())
	}
	name := want
	if name == "" {
		name = "HD-1080p"
	}
	for _, p := range ps {
		if strings.EqualFold(p.Name, name) {
			return p.ID, p.Name, nil
		}
	}
	if want != "" {
		names := make([]string, len(ps))
		for i, p := range ps {
			names[i] = p.Name
		}
		return 0, "", fmt.Errorf("%s has no quality profile %q (it has: %s)", c.name(), want, strings.Join(names, ", "))
	}
	return ps[0].ID, ps[0].Name, nil
}

func (c arr) rootFolder() (string, int64, error) {
	var rs []struct {
		Path      string `json:"path"`
		FreeSpace int64  `json:"freeSpace"`
	}
	if err := c.do("GET", "rootfolder", nil, &rs); err != nil {
		return "", 0, err
	}
	if len(rs) == 0 {
		return "", 0, fmt.Errorf("%s has no root folder", c.name())
	}
	return rs[0].Path, rs[0].FreeSpace, nil
}

func human(b int64) string {
	const g = 1 << 30
	if b >= g {
		return fmt.Sprintf("%.1f GB", float64(b)/g)
	}
	return fmt.Sprintf("%d MB", b>>20)
}

// queueRecord is one download in Radarr's or Sonarr's queue.
type queueRecord struct {
	Title    string  `json:"title"`
	Status   string  `json:"status"`
	State    string  `json:"trackedDownloadState"`
	Health   string  `json:"trackedDownloadStatus"`
	Size     float64 `json:"size"`
	SizeLeft float64 `json:"sizeleft"`
	TimeLeft string  `json:"timeleft"`
	Error    string  `json:"errorMessage"`
	Messages []struct {
		Messages []string `json:"messages"`
	} `json:"statusMessages"`
	Movie *struct {
		Title string `json:"title"`
		Year  int    `json:"year"`
	} `json:"movie"`
	Series *struct {
		Title string `json:"title"`
	} `json:"series"`
	Episode *struct {
		Season  int `json:"seasonNumber"`
		Episode int `json:"episodeNumber"`
	} `json:"episode"`
}

func (q queueRecord) label() string {
	switch {
	case q.Movie != nil && q.Movie.Year > 0:
		return fmt.Sprintf("%s (%d)", q.Movie.Title, q.Movie.Year)
	case q.Movie != nil:
		return q.Movie.Title
	case q.Series != nil && q.Episode != nil:
		return fmt.Sprintf("%s S%02dE%02d", q.Series.Title, q.Episode.Season, q.Episode.Episode)
	case q.Series != nil:
		return q.Series.Title
	}
	return q.Title
}

func (q queueRecord) progress() string {
	if q.Size <= 0 {
		return "  -"
	}
	return fmt.Sprintf("%3.0f%%", 100*(q.Size-q.SizeLeft)/q.Size)
}

// note is the first thing worth telling: an error, a warning, or why it waits.
func (q queueRecord) note() string {
	if q.Error != "" {
		return q.Error
	}
	for _, m := range q.Messages {
		for _, s := range m.Messages {
			if s != "" {
				return s
			}
		}
	}
	return ""
}

func (c arr) queue() ([]queueRecord, error) {
	extra := "includeMovie=true"
	if c.tv {
		extra = "includeSeries=true&includeEpisode=true"
	}
	var page struct {
		Records []queueRecord `json:"records"`
	}
	if err := c.do("GET", "queue?pageSize=200&"+extra, nil, &page); err != nil {
		return nil, err
	}
	return page.Records, nil
}

// wanted lists what is monitored, has no file and is not downloading: still searched for.
func (c arr) wanted() ([]string, error) {
	extra := ""
	if c.tv {
		extra = "&includeSeries=true"
	}
	var page struct {
		Total   int `json:"totalRecords"`
		Records []struct {
			Title  string `json:"title"`
			Year   int    `json:"year"`
			Series *struct {
				Title string `json:"title"`
			} `json:"series"`
		} `json:"records"`
	}
	if err := c.do("GET", "wanted/missing?pageSize=200&monitored=true"+extra, nil, &page); err != nil {
		return nil, err
	}
	if !c.tv {
		out := make([]string, 0, len(page.Records))
		for _, r := range page.Records {
			out = append(out, item{Title: r.Title, Year: r.Year}.label())
		}
		return out, nil
	}
	// Episodes: one line per series with its count.
	count := map[string]int{}
	for _, r := range page.Records {
		if r.Series != nil {
			count[r.Series.Title]++
		}
	}
	out := make([]string, 0, len(count))
	for t, n := range count {
		out = append(out, fmt.Sprintf("%s (%d episodes)", t, n))
	}
	sort.Strings(out)
	return out, nil
}

func mediaStatus(a *app, radarr, sonarr arr, watch bool) int {
	for {
		code := mediaStatusOnce(a, radarr, sonarr)
		if !watch || code != 0 {
			return code
		}
		time.Sleep(10 * time.Second)
		if a.tty {
			fmt.Fprint(a.stdout, "\033[H\033[2J")
		} else {
			fmt.Fprintln(a.stdout)
		}
	}
}

func mediaStatusOnce(a *app, radarr, sonarr arr) int {
	failed := false
	var downloads []queueRecord
	var wanted []string
	for _, c := range []arr{radarr, sonarr} {
		q, err := c.queue()
		if err != nil {
			fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
			failed = true
			continue
		}
		downloads = append(downloads, q...)
		w, err := c.wanted()
		if err != nil {
			fmt.Fprintf(a.stderr, "anvil: media: %v\n", err)
			failed = true
			continue
		}
		inQueue := map[string]bool{}
		for _, d := range q {
			inQueue[d.label()] = true
		}
		for _, x := range w {
			if !inQueue[x] {
				wanted = append(wanted, x)
			}
		}
	}

	fmt.Fprintln(a.stdout, "Downloading")
	if len(downloads) == 0 {
		fmt.Fprintln(a.stdout, "  nothing")
	}
	for _, d := range downloads {
		eta := d.TimeLeft
		if eta == "" {
			eta = "-"
		}
		state := d.State
		if state == "" {
			state = d.Status
		}
		fmt.Fprintf(a.stdout, "  %s  %-45s %9s  eta %-9s %s\n", d.progress(), oneLine(d.label(), 45), human(int64(d.Size)), eta, state)
		if n := d.note(); n != "" && d.Health != "ok" {
			fmt.Fprintf(a.stdout, "        %s\n", oneLine(n, 100))
		}
	}
	fmt.Fprintln(a.stdout, "Searching (added, nothing found or grabbed yet)")
	if len(wanted) == 0 {
		fmt.Fprintln(a.stdout, "  nothing")
	}
	for _, w := range wanted {
		fmt.Fprintf(a.stdout, "  %s\n", w)
	}
	for _, c := range []arr{radarr, sonarr} {
		if root, free, err := c.rootFolder(); err == nil {
			fmt.Fprintf(a.stdout, "Free space for %s: %s (%s)\n", map[bool]string{false: "movies", true: "series"}[c.tv], human(free), root)
		}
	}
	if failed {
		return 1
	}
	return 0
}
