module github.com/gaius-codius/go-ci

// The fixture module go-ci's own CI runs .github/workflows/go.yml against.
// go-ci is not a Go library; see fixture/fixture.go. The comment sits below the
// module line because gremlins reads the module path from the first line.

go 1.27.0

toolchain go1.27.2
