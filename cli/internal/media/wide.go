package media

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/memetics19/anvil/cli/internal/app"
)

// The wider season search. Sonarr searches a season as "<title> S02". Some packs are named
// otherwise ("<title> 2026 Hindi Season 02 Complete 1080p"): Sonarr's query does not find
// them, and Sonarr cannot parse their name when it sees one. When Sonarr finds no release it
// takes, anvil asks Prowlarr with more phrasings, keeps season packs at 1080p or 4K, and
// pushes the best one to Sonarr under a clean name ("<title> S02 1080p HDRip"). Sonarr
// still decides: it takes the push only when its profile allows it, and then follows and
// imports the download as its own.

// How long widerSeason waits for Sonarr to record the grab of a pushed release, and how
// often it looks. Sonarr hands it to qBittorrent within seconds. Tests set these near zero.
var (
	queueWait = 30 * time.Second
	queuePoll = 2 * time.Second
)

// slowClient is for the calls that search the indexers: they take half a minute or more.
// Prowlarr answers with what it has after its own per-indexer timeouts, well within this.
var slowClient = &http.Client{Timeout: 3 * time.Minute}

type release struct {
	Title      string `json:"title"`
	Rejected   bool   `json:"rejected"`
	Rejections []any  `json:"rejections"`
}

// firstReason is a release's first rejection, as text (Sonarr sends a string or an object).
func (r release) firstReason() string {
	if len(r.Rejections) == 0 {
		return ""
	}
	switch x := r.Rejections[0].(type) {
	case string:
		return x
	case map[string]any:
		if s, ok := x["reason"].(string); ok {
			return s
		}
	}
	return ""
}

type hit struct {
	GUID        string `json:"guid"`
	Title       string `json:"title"`
	Size        int64  `json:"size"`
	Seeders     int    `json:"seeders"`
	Indexer     string `json:"indexer"`
	DownloadURL string `json:"downloadUrl"`
	MagnetURL   string `json:"magnetUrl"`
	PublishDate string `json:"publishDate"`
	Protocol    string `json:"protocol"`
	res         int
}

// prowlarrSearch asks every Prowlarr indexer for query.
func prowlarrSearch(ep arrEndpoint, query string) ([]hit, error) {
	q := url.Values{"query": {query}, "type": {"search"}, "limit": {"100"}}
	req, err := http.NewRequest("GET", strings.TrimRight(ep.URL, "/")+"/api/v1/search?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Api-Key", ep.Key)
	resp, err := slowClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Prowlarr: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("Prowlarr: search returned %d: %s", resp.StatusCode, arrError(data))
	}
	var hs []hit
	if err := json.Unmarshal(data, &hs); err != nil {
		return nil, fmt.Errorf("Prowlarr: %v", err)
	}
	return hs, nil
}

var (
	nonWord   = regexp.MustCompile(`[^a-z0-9]+`)
	resRE     = regexp.MustCompile(`(?i)\b(2160p|4k|uhd|1080p|720p|576p|480p)\b`)
	sourceRE  = regexp.MustCompile(`(?i)\b(web-?dl|webrip|hdrip|blu-?ray|bdrip|hdtv)\b`)
	languages = []string{"Hindi", "Tamil", "Telugu", "Kannada", "Malayalam", "Bengali", "Marathi", "English"}
)

func words(s string) string {
	return strings.TrimSpace(nonWord.ReplaceAllString(strings.ToLower(s), " "))
}

func resolution(title string) int {
	switch strings.ToLower(resRE.FindString(title)) {
	case "2160p", "4k", "uhd":
		return 2160
	case "1080p":
		return 1080
	case "720p":
		return 720
	case "576p", "480p":
		return 480
	}
	return 0
}

// seasonPack reports whether title is the whole season n of the series: it starts with the
// series' name, names season n, and names no episode.
func seasonPack(series, title string, n int) bool {
	w := words(title)
	if !strings.HasPrefix(w+" ", words(series)+" ") {
		return false
	}
	season := regexp.MustCompile(fmt.Sprintf(`\b(s0*%d|season 0*%d)\b`, n, n))
	episode := regexp.MustCompile(`\bs\d+ ?e\d+\b|\bepisode\b`)
	return season.MatchString(w) && !episode.MatchString(w)
}

// cleanName is the name Sonarr can parse: "<title> S02 1080p HDRip Hindi".
func cleanName(series string, n int, h hit) string {
	res := "1080p"
	if h.res == 2160 {
		res = "2160p"
	}
	parts := []string{series, fmt.Sprintf("S%02d", n), res}
	if s := sourceRE.FindString(h.Title); s != "" {
		parts = append(parts, s)
	}
	for _, l := range languages {
		if regexp.MustCompile(`(?i)\b` + l + `\b`).MatchString(h.Title) {
			parts = append(parts, l)
			break
		}
	}
	return strings.Join(parts, " ")
}

// widerSeason runs after the season search has started. It returns false only on an error
// worth an exit code: finding nothing is not one, since Sonarr keeps watching the season.
func (c arr) widerSeason(a *app.App, prowlarr arrEndpoint, series string, seriesID, n int) bool {
	fmt.Fprintf(a.Stdout, "Checking what %s finds for season %d...\n", c.name(), n)
	slow := c
	slow.client = slowClient
	var rels []release
	if err := slow.do("GET", fmt.Sprintf("release?seriesId=%d&seasonNumber=%d", seriesID, n), nil, &rels); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
		return false
	}
	reasons := map[string]int{}
	for _, r := range rels {
		if !r.Rejected {
			fmt.Fprintf(a.Stdout, "%s found a release it takes, and downloads it.\n", c.name())
			return true
		}
		if s := r.firstReason(); s != "" {
			reasons[s]++
		}
	}
	if len(rels) == 0 {
		fmt.Fprintf(a.Stdout, "%s found no release for season %d.\n", c.name(), n)
	} else {
		var why []string
		for s, k := range reasons {
			why = append(why, fmt.Sprintf("%s (%d)", s, k))
		}
		sort.Strings(why)
		fmt.Fprintf(a.Stdout, "%s found %d release(s) for season %d and takes none: %s.\n", c.name(), len(rels), n, strings.Join(why, ", "))
	}
	if prowlarr.URL == "" || prowlarr.Key == "" {
		fmt.Fprintln(a.Stdout, "The wider search needs Prowlarr (scripts/media-env.sh). Sonarr keeps watching the season.")
		return true
	}

	fmt.Fprintln(a.Stdout, "Searching wider through Prowlarr...")
	// The phrasings run at once: Prowlarr asks every indexer for each, and the slow ones
	// (behind FlareSolverr) take a minute or more.
	queries := []string{fmt.Sprintf("%s Season %d", series, n), fmt.Sprintf("%s S%02d", series, n), series}
	results := make([][]hit, len(queries))
	errs := make([]error, len(queries))
	var wg sync.WaitGroup
	for i, q := range queries {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], errs[i] = prowlarrSearch(prowlarr, q)
		}()
	}
	wg.Wait()
	seen := map[string]bool{}
	var packs []hit
	for i, hs := range results {
		if errs[i] != nil {
			fmt.Fprintf(a.Stderr, "anvil: media: %v\n", errs[i])
			continue
		}
		for _, h := range hs {
			key := h.GUID + "|" + h.Title
			if seen[key] || !strings.EqualFold(h.Protocol, "torrent") || !seasonPack(series, h.Title, n) {
				continue
			}
			seen[key] = true
			if h.res = resolution(h.Title); h.res >= 1080 {
				packs = append(packs, h)
			}
		}
	}
	// 1080p before 4K (the policy prefers 1080p: a 4K pack can be ten times the size), then
	// the most seeders.
	sort.SliceStable(packs, func(i, j int) bool {
		if (packs[i].res == 1080) != (packs[j].res == 1080) {
			return packs[i].res == 1080
		}
		return packs[i].Seeders > packs[j].Seeders
	})
	if len(packs) == 0 {
		fmt.Fprintf(a.Stdout, "No season %d pack at 1080p or better anywhere yet. Sonarr keeps watching the season.\n", n)
		return true
	}
	// Sonarr downloads a release through the indexer it came from: that indexer follows
	// Prowlarr's download link to the torrent or magnet. Its id is Sonarr's, matched by name
	// ("kickasstorrents.to (Prowlarr)").
	var idx []struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}
	if err := c.do("GET", "indexer", nil, &idx); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
		return false
	}
	indexerID := func(name string) int {
		for _, i := range idx {
			if strings.EqualFold(i.Name, name) || strings.EqualFold(i.Name, name+" (Prowlarr)") {
				return i.ID
			}
		}
		return 0
	}
	for i, h := range packs {
		if i == 3 {
			break
		}
		name := cleanName(series, n, h)
		body := map[string]any{"title": name, "protocol": "torrent", "publishDate": h.PublishDate,
			"indexer": h.Indexer, "size": h.Size, "seeders": h.Seeders}
		if h.DownloadURL != "" {
			body["downloadUrl"] = h.DownloadURL
		} else {
			body["downloadUrl"] = h.MagnetURL
		}
		// Prowlarr often puts its own download link in magnetUrl too. Sonarr would try to
		// parse that as a magnet and fail, so only a real magnet goes there. The download link
		// is followed through the indexer, to a torrent or a magnet, as in Sonarr's own grabs.
		if strings.HasPrefix(h.MagnetURL, "magnet:") {
			body["magnetUrl"] = h.MagnetURL
		}
		if id := indexerID(h.Indexer); id > 0 {
			body["indexerId"] = id
		}
		var out []release
		if err := slow.do("POST", "release/push", body, &out); err != nil {
			fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
			continue
		}
		if len(out) > 0 && !out[0].Rejected {
			// Taken is not downloading yet: Sonarr still has to hand it to qBittorrent.
			if c.grabbed(seriesID, name) {
				fmt.Fprintf(a.Stdout, "Found %q (%s, %d seeders, %s).\nGave it to %s as %q, and it is downloading. Follow it with: anvil media status\n",
					h.Title, human(h.Size), h.Seeders, h.Indexer, c.name(), name)
				return true
			}
			fmt.Fprintf(a.Stdout, "%s took %q but did not start the download (its log, Activity, says why).\n", c.name(), h.Title)
			continue
		}
		why := "no reason given"
		if len(out) > 0 && out[0].firstReason() != "" {
			why = out[0].firstReason()
		}
		fmt.Fprintf(a.Stdout, "%s does not take %q: %s\n", c.name(), h.Title, why)
	}
	fmt.Fprintf(a.Stdout, "Nothing it takes yet. Sonarr keeps watching season %d.\n", n)
	return true
}

// grabbed waits for Sonarr's history to record the grab of a release, by the name it was
// pushed under. The queue is no use for this: it shows the torrent's own name.
func (c arr) grabbed(seriesID int, title string) bool {
	deadline := time.Now().Add(queueWait)
	for {
		var hs []struct {
			SourceTitle string `json:"sourceTitle"`
		}
		if err := c.do("GET", fmt.Sprintf("history/series?seriesId=%d&eventType=1", seriesID), nil, &hs); err == nil {
			for _, h := range hs {
				if strings.EqualFold(h.SourceTitle, title) {
					return true
				}
			}
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(queuePoll)
	}
}
