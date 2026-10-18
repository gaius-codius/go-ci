# go-ci

Shared CI for gaius-codius Go projects: one reusable workflow, a vulnerability gate, and a baseline golangci-lint config. Projects pin a release by commit SHA and keep their own allowlist and release jobs. The Go module must be at the repository root.

| Piece | Where | How a project uses it |
|---|---|---|
| Reusable workflow | `.github/workflows/go.yml` | Called from the project's `ci.yml` |
| govulncheck gate | `actions/govulncheck`, `baseline/scripts/govulncheck.sh` | Run by the workflow; the project keeps a copy of the script for local runs and its own `scripts/govulncheck-allow.txt` |
| Baseline drift check | `actions/baseline-drift` | Run by the workflow; warns, never fails |
| Silenced-checks report | `actions/silenced-checks` | Run by the workflow on pull requests; warns, never fails |
| Diff-coverage gate | `actions/diff-coverage` | Run by the workflow on pull requests when `diff-coverage` is set |
| Changed-lines lint | `actions/changed-lines-lint` | Run by the workflow on pull requests with the `new-code-linters` |
| Lint config | `baseline/.golangci.yml` | Copied to the project root (golangci-lint can't load a remote config) |
| Lint helper | `baseline/scripts/lint-packages.sh` | Copied to `scripts/` |
| Toolchain pins | `mise.toml` | The tool versions CI installs; a project keeps its own `mise.toml` |
| Update policy | `renovate/go.json5` | Extended from the project's `renovate.json5` |

## Calling the workflow

```yaml
permissions:
  contents: read

jobs:
  verify:
    uses: gaius-codius/go-ci/.github/workflows/go.yml@<release commit SHA> # v2.x.y
    with:
      runs-on: '["self-hosted","linux","x64","<project>"]'
      build: ./cmd/<project>/
      fuzz: |
        ./internal/config FuzzLoad
```

Tools come from the project's `mise.toml` (Go, golangci-lint, govulncheck, jq, and optionally shellcheck, deadcode, nilaway, gorelease and gremlins). The status check is named `verify / test-vet-build`.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `runs-on` | required | Runner labels as a JSON list |
| `build` | `""` (builds `./...`) | Package to build |
| `fuzz` | `""` | One `<package> <FuzzName>` per line |
| `fuzz-time` | `5s` | Time per fuzz target |
| `govulncheck-allowlist` | `scripts/govulncheck-allow.txt` | Allowlist path |
| `mise-cache` | `false` | Turn on for GitHub-hosted runners |
| `tidy-check` | `false` | Fail when `go mod tidy -diff` finds changes |
| `timeout-minutes` | `30` | Job timeout (GitHub's default is 6 hours) |
| `shellcheck` | `""` (off) | Space- or newline-separated paths or globs of scripts to check; needs `shellcheck` in `mise.toml` |
| `deadcode` | `false` | Report unreachable functions; needs `deadcode` in `mise.toml`. Reports only, and only finds code unreachable from `main` packages |
| `new-code-linters` | `gocognit,nestif,wrapcheck` | Linters pull requests must pass on changed lines; `""` turns it off. Their settings come from `.golangci.yml` |
| `dependency-review` | `auto` | `auto` (public repositories), `true` or `false` |
| `diff-coverage` | `0` (off) | Minimum percentage of changed code lines covered by tests |
| `nilaway` | `false` | Report possible nil dereferences; needs `nilaway` in `mise.toml` |
| `gorelease` | `false` | Report API changes for a library module; needs `gorelease` in `mise.toml` |
| `mutation` | `false` | Run gremlins mutation testing; slow, so turn it on for scheduled or manual runs only; needs `gremlins` in `mise.toml` |

## Pinning

Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/go-ci 'v2.*'`), as for any third-party action: the workflow runs on your runner with your checkout. Renovate keeps the pin current. A project extends the update policy from its `renovate.json5`:

```json5
{
  $schema: 'https://docs.renovatebot.com/renovate-schema.json',
  extends: ['github>gaius-codius/go-ci//renovate/go.json5'],
}
```

The preset loads from `main`, not from a release.

## Upgrading

When Renovate bumps go-ci, compare `baseline/.golangci.yml` between the old and new tags and merge its changes (new linters, wrapcheck settings, exclusions) into the project's `.golangci.yml`; the project's copy doesn't update itself. The drift check warns when the enabled linters differ, the wrapcheck settings are missing, or the `PROJECT` placeholder is left in.

## Releases

A release is one commit tagged `vX.Y.Z`:

1. In `.github/workflows/go.yml`, set every `gaius-codius/go-ci/actions/...@` reference to the new tag, so a project pinning this commit gets the actions from the same release. CI checks this when the tag is pushed.
2. Commit, tag, and push the commit and the tag together (`git push --atomic origin main vX.Y.Z`). The release commit's `go-workflow` job can only resolve the new action references once the tag exists, so that failure on a release pull request is expected; the run for the tag push is the one that counts.
3. Never move or delete a release tag. A repository ruleset rejects updates and deletions of `v*` tags.

A change that would fail a project that passed before (a stricter gate, a new required input) is a new major version. CI runs the tests under `tests/`, shellcheck and actionlint, and runs `go.yml` itself against a fixture module at the repository root (`go.mod`, `fixture/`, `mise.toml`, and symlinks to `baseline/.golangci.yml` and `baseline/scripts/`). When you bump Go in `mise.toml`, change the `toolchain` line in `go.mod` in the same commit. With mise activated in your shell, run `mise trust` once in a clone.
