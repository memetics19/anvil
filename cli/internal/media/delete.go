package media

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
)

// libraryItem is a movie or a series already in Radarr or Sonarr.
type libraryItem struct {
	ID         int    `json:"id"`
	Title      string `json:"title"`
	Year       int    `json:"year"`
	SizeOnDisk int64  `json:"sizeOnDisk"`
	Stats      *struct {
		SizeOnDisk int64 `json:"sizeOnDisk"`
	} `json:"statistics"`
}

func (it libraryItem) label() string {
	return item{Title: it.Title, Year: it.Year}.label()
}

// size is what deleting the files frees. Sonarr keeps it under statistics.
func (it libraryItem) size() int64 {
	if it.Stats != nil && it.Stats.SizeOnDisk > 0 {
		return it.Stats.SizeOnDisk
	}
	return it.SizeOnDisk
}

// library lists the library items whose title holds every word of term, by title and year.
func (c arr) library(term string) ([]libraryItem, error) {
	var all []libraryItem
	if err := c.do("GET", c.kind(), nil, &all); err != nil {
		return nil, err
	}
	want := strings.Fields(words(term))
	var out []libraryItem
	for _, it := range all {
		title := " " + words(it.Title) + " "
		match := true
		for _, w := range want {
			if !strings.Contains(title, " "+w+" ") {
				match = false
				break
			}
		}
		if match {
			out = append(out, it)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Title != out[j].Title {
			return out[i].Title < out[j].Title
		}
		return out[i].Year < out[j].Year
	})
	return out, nil
}

// downloads are the queue entries of one library item.
func (c arr) downloads(id int) ([]int, error) {
	var page struct {
		Records []struct {
			ID       int `json:"id"`
			MovieID  int `json:"movieId"`
			SeriesID int `json:"seriesId"`
		} `json:"records"`
	}
	if err := c.do("GET", "queue?pageSize=200", nil, &page); err != nil {
		return nil, err
	}
	var ids []int
	for _, r := range page.Records {
		if (c.tv && r.SeriesID == id) || (!c.tv && r.MovieID == id) {
			ids = append(ids, r.ID)
		}
	}
	return ids, nil
}

func mediaDelete(a *app.App, c arr, term string, o mediaOpts) int {
	items, err := c.library(term)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
		return 1
	}
	if len(items) == 0 {
		fmt.Fprintf(a.Stdout, "No %s in the library matches %q.\n", c.kind(), term)
		return 1
	}
	if len(items) > mediaListMax {
		items = items[:mediaListMax]
	}
	choice := o.pick
	switch {
	case choice > 0:
		if choice > len(items) {
			fmt.Fprintf(a.Stderr, "anvil: media: --pick %d, but there are %d matches\n", choice, len(items))
			return 2
		}
	case len(items) == 1:
		choice = 1
	default:
		for i, it := range items {
			fmt.Fprintf(a.Stdout, "%3d. %s  [%s]\n", i+1, it.label(), human(it.size()))
		}
		fmt.Fprintf(a.Stdout, "Which one? [1-%d] ", len(items))
		ans, ok := app.ReadLine(a.Stdin)
		n, err := strconv.Atoi(ans)
		if !ok || err != nil || n < 1 || n > len(items) {
			fmt.Fprintln(a.Stdout, "\nNothing deleted.")
			return 1
		}
		choice = n
	}
	it := items[choice-1]

	what := fmt.Sprintf("%s and its files (%s)", it.label(), human(it.size()))
	if o.keepFiles {
		what = it.label() + " from " + c.name() + ", keeping its files"
	}
	if !o.yes && !app.AskYesNo(a.Stdin, a.Stdout, "Delete "+what+"?") {
		fmt.Fprintln(a.Stdout, "Nothing deleted.")
		return 1
	}

	// Downloads first: once the item is gone, its queue entries would finish into nothing.
	queued, err := c.downloads(it.ID)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
		return 1
	}
	for _, q := range queued {
		if err := c.do("DELETE", fmt.Sprintf("queue/%d?removeFromClient=true&blocklist=false", q), nil, nil); err != nil {
			fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
			return 1
		}
	}
	files := strconv.FormatBool(!o.keepFiles)
	if err := c.do("DELETE", fmt.Sprintf("%s/%d?deleteFiles=%s&addImportExclusion=false&addImportListExclusion=false", c.kind(), it.ID, files), nil, nil); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: media: %v\n", err)
		return 1
	}

	done := "Deleted " + what + "."
	if len(queued) > 0 {
		done += fmt.Sprintf(" Stopped %d download(s).", len(queued))
	}
	fmt.Fprintln(a.Stdout, done)
	return 0
}
