package media

import (
	"strings"
	"testing"
	"time"
)

func TestSeasonPackAndResolution(t *testing.T) {
	for title, want := range map[string]bool{
		"Bakaiti 2026 Hindi Season 02 Complete 1080p HDRip ESubs": true,
		"Bakaiti.S02.WEB-DL.Hindi.1080p":                          true,
		"Bakaiti S2 2160p WEB-DL":                                 true,
		"Bakaiti S01 2160p ZEE5 WEB-DL":                           false, // another season
		"Bakaiti S02E01 1080p WEB-DL":                             false, // an episode
		"Not Bakaiti S02 1080p":                                   false, // another show
		"Bakaiti Season 20 1080p":                                 false,
	} {
		if got := seasonPack("Bakaiti", title, 2); got != want {
			t.Errorf("seasonPack(%q) = %v, want %v", title, got, want)
		}
	}
	for title, want := range map[string]int{"x 1080p y": 1080, "x 4K y": 2160, "x.2160p.y": 2160, "x 720p": 720, "x": 0} {
		if got := resolution(title); got != want {
			t.Errorf("resolution(%q) = %d, want %d", title, got, want)
		}
	}
	h := hit{Title: "Bakaiti 2026 Hindi Season 02 Complete 1080p HDRip ESubs", res: 1080}
	if got := cleanName("Bakaiti", 2, h); got != "Bakaiti S02 1080p HDRip Hindi" {
		t.Errorf("cleanName = %q", got)
	}
}

const bakaitiLookup = `[{"title":"Bakaiti","year":2025,"tvdbId":466383,"id":5,"seasons":[{"seasonNumber":1},{"seasonNumber":2}]}]`

const bakaitiHits = `[
 {"guid":"a","title":"Bakaiti 2026 Hindi Season 02 Complete 720p HDRip ESubs","size":1652000000,"seeders":5,"indexer":"kat","magnetUrl":"magnet:?xt=urn:btih:a","protocol":"torrent"},
 {"guid":"b","title":"Bakaiti S02 2160p WEB-DL","size":9000000000,"seeders":40,"indexer":"kat","magnetUrl":"magnet:?xt=urn:btih:b","protocol":"torrent"},
 {"guid":"c","title":"Bakaiti 2026 Hindi Season 02 Complete 1080p HDRip ESubs","size":2941000000,"seeders":3,"indexer":"kat","downloadUrl":"http://prowlarr/c","magnetUrl":"http://prowlarr/c?file=x","protocol":"torrent"},
 {"guid":"d","title":"Bakaiti S01 2160p ZEE5 WEB-DL","size":2300000000,"seeders":33,"indexer":"1337x","magnetUrl":"magnet:?xt=urn:btih:d","protocol":"torrent"},
 {"guid":"e","title":"Bakaiti S02E01 1080p","size":300000000,"seeders":9,"indexer":"kat","magnetUrl":"magnet:?xt=urn:btih:e","protocol":"torrent"}]`

const rejected720 = `[{"title":"Bakaiti.S02 WEB-DL Hindi 720p","rejected":true,"rejections":["WEBDL-720p is not wanted in profile"]}]`

func TestMediaWiderSeason(t *testing.T) {
	defer func(w, p time.Duration) { episodeWait, episodePoll = w, p }(episodeWait, episodePoll)
	episodeWait, episodePoll = 2*time.Second, time.Millisecond
	defer func(w, p time.Duration) { queueWait, queuePoll = w, p }(queueWait, queuePoll)
	queueWait, queuePoll = 20*time.Millisecond, time.Millisecond

	// Sonarr takes nothing: the 1080p pack is pushed under a clean name, before the 4K one.
	sonarr := &fakeArr{tv: true, lookup: bakaitiLookup, releases: rejected720}
	prowlarr := &fakeProwlarr{hits: bakaitiHits}
	l := mediaLabProwlarr(t, sonarr, prowlarr)
	if code := l.Run("", "media", "get", "bakaiti", "--tv", "--season", "2"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	push := sonarr.posts["release/push"]
	if len(push) != 1 || push[0]["title"] != "Bakaiti S02 1080p HDRip Hindi" || push[0]["downloadUrl"] != "http://prowlarr/c" ||
		push[0]["indexerId"] != float64(15) || push[0]["magnetUrl"] != nil {
		t.Fatalf("pushes = %v", push)
	}
	out := l.Out.String()
	for _, want := range []string{"takes none: WEBDL-720p is not wanted in profile (1)", "Gave it to Sonarr as \"Bakaiti S02 1080p HDRip Hindi\", and it is downloading"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if q := strings.Join(prowlarr.queries, "|"); !strings.Contains(q, "Bakaiti Season 2") || !strings.Contains(q, "Bakaiti S02") {
		t.Errorf("queries = %q", prowlarr.queries)
	}
	noKeyIn(t, l)

	// Sonarr rejects the first push: the next pack (4K) is tried.
	sonarr2 := &fakeArr{tv: true, lookup: bakaitiLookup, releases: rejected720, pushes: []bool{true}}
	l2 := mediaLabProwlarr(t, sonarr2, &fakeProwlarr{hits: bakaitiHits})
	if code := l2.Run("", "media", "get", "bakaiti", "--tv", "--season", "2"); code != 0 {
		t.Fatalf("second push: exit %d: %s", code, l2.Output())
	}
	if p := sonarr2.posts["release/push"]; len(p) != 2 || p[1]["title"] != "Bakaiti S02 2160p WEB-DL" {
		t.Fatalf("second push: pushes = %v", p)
	}

	// Sonarr takes the push but never starts it: not reported as downloading, the next is tried.
	sonarr6 := &fakeArr{tv: true, lookup: bakaitiLookup, releases: rejected720, noGrab: true}
	l6 := mediaLabProwlarr(t, sonarr6, &fakeProwlarr{hits: bakaitiHits})
	if code := l6.Run("", "media", "get", "bakaiti", "--tv", "--season", "2"); code != 0 {
		t.Fatalf("no grab: exit %d: %s", code, l6.Output())
	}
	if p := sonarr6.posts["release/push"]; len(p) != 2 || strings.Contains(l6.Out.String(), "is downloading") ||
		!strings.Contains(l6.Out.String(), "did not start the download") {
		t.Fatalf("no grab: pushes %v:\n%s", p, l6.Out.String())
	}

	// Sonarr has a release it takes: no wider search, no push.
	sonarr3 := &fakeArr{tv: true, lookup: bakaitiLookup, releases: `[{"title":"Bakaiti S02 1080p","rejected":false}]`}
	prowlarr3 := &fakeProwlarr{hits: bakaitiHits}
	l3 := mediaLabProwlarr(t, sonarr3, prowlarr3)
	if code := l3.Run("", "media", "get", "bakaiti", "--tv", "--season", "2"); code != 0 || len(prowlarr3.queries) != 0 || len(sonarr3.posts["release/push"]) != 0 {
		t.Fatalf("taken: exit %d, queries %q, pushes %v", code, prowlarr3.queries, sonarr3.posts["release/push"])
	}

	// No pack at 1080p or better: nothing pushed, Sonarr keeps watching, exit 0.
	sonarr4 := &fakeArr{tv: true, lookup: bakaitiLookup, releases: rejected720}
	l4 := mediaLabProwlarr(t, sonarr4, &fakeProwlarr{hits: `[{"guid":"a","title":"Bakaiti S02 720p","seeders":5,"protocol":"torrent","magnetUrl":"m"}]`})
	if code := l4.Run("", "media", "get", "bakaiti", "--tv", "--season", "2"); code != 0 || len(sonarr4.posts["release/push"]) != 0 ||
		!strings.Contains(l4.Out.String(), "No season 2 pack at 1080p or better") {
		t.Fatalf("none: exit %d, pushes %v:\n%s", code, sonarr4.posts["release/push"], l4.Out.String())
	}

	// No Prowlarr: said so, nothing pushed, exit 0.
	sonarr5 := &fakeArr{tv: true, lookup: bakaitiLookup, releases: rejected720}
	l5 := mediaLab(t, &fakeArr{}, sonarr5)
	if code := l5.Run("", "media", "get", "bakaiti", "--tv", "--season", "2"); code != 0 || !strings.Contains(l5.Out.String(), "needs Prowlarr") {
		t.Fatalf("no prowlarr: exit %d:\n%s", code, l5.Out.String())
	}
}
