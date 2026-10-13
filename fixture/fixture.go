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
