## Go style

Lint must pass before you hand work back. Follow the `go-style` skill (gaius-codius/skills), which covers [Effective Go](https://go.dev/doc/effective_go), [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments), the [Google Go style guide](https://google.github.io/styleguide/go/) and these house rules:

- Errors returned from other modules and the standard library get context added with `fmt.Errorf`, saying what failed; errors from this project's own packages may be returned as they are. Compare with `errors.Is`/`errors.As`. Whether to wrap with `%w` or `%v` is this project's policy: <state it here, for example "always `%w`">.
- `context.Context` is the first parameter, is never stored in a struct, and is passed on rather than replaced with `context.Background()`.
- Test helpers call `t.Helper()` first; tests use `t.TempDir`, `t.Setenv` and `t.Context` instead of the `os` and `context` versions.
- Sentinel errors are named `errXxx`/`ErrXxx`, error types `XxxError`.
- Fix a failing check; don't switch it off. A `//nolint:<linter> // reason`, a `t.Skip`, a `.golangci.yml` change or a govulncheck allowlist entry needs a reason, and CI flags each one for a person to review. Ask before adding one.
- Keep changed code simple: on pull requests CI fails changed lines that make a function too complex (gocognit), nest `if`s deeply (nestif), or return another module's or the standard library's error without context (wrapcheck). CI checks against the merge base; the pre-commit hook runs a narrower version of the check, against HEAD. gocognit reports on a function's `func` line, so changing an existing complex function's signature counts as a change: refactor the function rather than adding a `//nolint`.

Apply auto-fixable findings with `golangci-lint run --fix` (or `go fix ./...` for API migrations), never by hand.

Use the `LSP` tool (gopls) for definitions, references and call sites before grepping for them. Its diagnostics don't replace lint: still run `golangci-lint run ./...`.

Claude Code formats each `.go` file you edit and lints its package through a user-level hook, and reports findings back in the same session. Fix them before moving on.

## Before opening a PR

Run all of these and make sure they pass (in a mise-activated shell, or prefix each with `mise exec --`):

```sh
go test ./...
go test -race ./...
go vet ./...
go mod tidy -diff
golangci-lint run ./...
golangci-lint run --enable-only=gocognit,nestif,wrapcheck --new-from-merge-base=origin/HEAD ./...  # or your default branch
./scripts/govulncheck.sh
go build ./cmd/<project>/
```
