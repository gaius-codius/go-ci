## Go style

Lint must pass before you hand work back. Follow the `go-style` skill (gaius-codius/skills), which covers [Effective Go](https://go.dev/doc/effective_go), [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments), the [Google Go style guide](https://google.github.io/styleguide/go/) and these house rules:

- Wrap errors with `%w` and add context; compare with `errors.Is`/`errors.As`.
- `context.Context` is the first parameter and is never stored in a struct.
- Suppress a finding only with `//nolint:<linter> // reason`.

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
./scripts/govulncheck.sh
go build ./cmd/<project>/
```
