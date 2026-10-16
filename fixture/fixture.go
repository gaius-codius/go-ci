// Package fixture stands in for a project that has adopted go-ci, so go-ci's
// own CI can run .github/workflows/go.yml before a release. The rest of that
// project is at the repository root: go.mod, and symlinks to this repo's
// mise.toml template, baseline .golangci.yml and baseline scripts, so a pull
// request runs the workflow against its own baseline.
package fixture

import "strings"

// Words splits s into the words between runs of white space.
func Words(s string) []string {
	return strings.Fields(s)
}

// CountAtLeast returns how many of words are at least n bytes long. It gives
// the mutation-testing step something to mutate.
func CountAtLeast(words []string, n int) int {
	count := 0
	for _, w := range words {
		if len(w) >= n {
			count++
		}
	}
	return count
}
