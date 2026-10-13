# go-ci

Shared quality setup for gaius-codius Go projects: one reusable CI workflow, a vulnerability gate, a baseline golangci-lint config, shared git hooks, and templates. Projects pin a release by commit SHA and keep their own allowlist and release jobs. The Go module must be at the repository root.

| Piece | Where | How a project uses it |
|---|---|---|
| Reusable workflow | `.github/workflows/go.yml` | Called from the project's `ci.yml` |
| govulncheck gate | `actions/govulncheck`, `baseline/scripts/govulncheck.sh` | Run by the workflow; the project keeps a copy of the script for local runs and its own `scripts/govulncheck-allow.txt` |
| Baseline drift check | `actions/baseline-drift` | Run by the workflow; warns, never fails |
| Lint config | `baseline/.golangci.yml` | Copied to the project root (golangci-lint can't load a remote config) |
| Lint helper | `baseline/scripts/lint-packages.sh` | Copied to `scripts/`; the hooks call it |
| Git hooks | `lefthook/go.yml` | Loaded through lefthook `remotes:`, pinned to a tag |
| Toolchain pins | `templates/mise.toml` | Copied once; bump versions per project |
| Agent guide section | `templates/AGENTS-go-style.md` | Copied into the project's `AGENTS.md` |

## What the workflow checks

In order, on the runner the caller names:

1. Go from `mise.toml` is the Go that runs, and `go.mod`'s `toolchain` line matches it.
2. Drift from this baseline (warnings only).
3. `go test -shuffle=on` with a coverage summary in the job summary (a trend, not a gate).
4. `go test -race -shuffle=on`.
5. Fuzz targets, if the caller lists any, for `fuzz-time` each.
6. `go vet`, `golangci-lint run`.
7. The govulncheck gate: any reachable vulnerability not in the allowlist fails.
8. `go build` of the `build` package (or `./...`).

Inputs:

| Input | Default | Meaning |
|---|---|---|
| `runs-on` | required | Runner labels as a JSON list |
| `build` | `""` (builds `./...`) | Package to build |
| `fuzz` | `""` | One `<package> <FuzzName>` per line |
| `fuzz-time` | `5s` | Time per fuzz target |
| `govulncheck-allowlist` | `scripts/govulncheck-allow.txt` | Allowlist path |
| `mise-cache` | `false` | Turn on for GitHub-hosted runners |

## Adopting it

Run these from the project's root. Replace `<project>` with the repo name and module path's last element.

1. **Toolchain.** Copy `templates/mise.toml` to `mise.toml` (or merge its `[tools]` and `[env]` into an existing one), then:

   ```sh
   mise install
   go mod edit -toolchain=go$(mise current go)
   ```

2. **Lint config and scripts.**

   ```sh
   GOCI=/path/to/go-ci   # a clone of this repo at the tag you pin
   cp "$GOCI/baseline/.golangci.yml" .golangci.yml
   mkdir -p scripts
   cp "$GOCI/baseline/scripts/govulncheck.sh" "$GOCI/baseline/scripts/lint-packages.sh" scripts/
   ```

   In `.golangci.yml`, set `formatters.settings.goimports.local-prefixes` to the module path. Add project exclusions (for example gosec `G204`) with a reason. Create `scripts/govulncheck-allow.txt`; it may hold only comments:

   ```text
   # Reachable govulncheck findings accepted for now, one OSV ID per line.
   # Each entry needs a reason and the issue that removes it.
   ```

   Run `golangci-lint run ./...` and `./scripts/govulncheck.sh`, and fix or allowlist what they find before switching CI.

3. **CI.** Replace the project's test job in `.github/workflows/ci.yml`:

   ```yaml
   permissions:
     contents: read

   jobs:
     verify:
       uses: gaius-codius/go-ci/.github/workflows/go.yml@<release commit SHA> # v1.x.y
       with:
         runs-on: '["self-hosted","linux","x64","<project>"]'
         build: ./cmd/<project>/
         fuzz: |
           ./internal/config FuzzLoad
   ```

   Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/go-ci 'v1.*'`), as for any third-party action: the workflow runs on your runner with your checkout. Dependabot's `github-actions` updates keep the pin current. The status check is then named `verify / test-vet-build`. Release jobs stay in the project and can keep `needs: verify`. Steps that only one project needs (an extra package, a service) go in a separate job in the project's `ci.yml`.

4. **Runner.** `gaius-codius` is a personal account, so a self-hosted runner serves one repository. Register one runner instance per repo on the runner host, each in its own directory and systemd service, with the repo name as an extra label:

   ```sh
   # Token: repo Settings → Actions → Runners → New self-hosted runner, or
   #   gh api -X POST repos/gaius-codius/<project>/actions/runners/registration-token --jq .token
   mkdir ~/actions-runner-<project> && cd ~/actions-runner-<project>
   # download and unpack the runner tarball shown on that settings page, then:
   ./config.sh --url https://github.com/gaius-codius/<project> --token <token> \
     --name <host>-<project> --labels <project> --unattended
   sudo ./svc.sh install && sudo ./svc.sh start
   ```

   The runner needs no tools installed beyond the runner itself: jdx/mise-action installs mise and the pinned tools. A GitHub-hosted runner works too: `runs-on: '["ubuntu-latest"]'` with `mise-cache: true`.

   Never run a self-hosted runner for a public repository: a fork's pull request could run code on the host. Public projects use `ubuntu-latest`, which is free for them.

5. **Git hooks.** Replace the project's `lefthook.yml` with:

   ```yaml
   remotes:
     - git_url: https://github.com/gaius-codius/go-ci
       ref: v1.x.y   # the release your ci.yml pins
       configs:
         - lefthook/go.yml
   ```

   then `lefthook install`. Lefthook fetches a remote once per ref, so bump `ref` with the CI pin. It refuses to install while `core.hooksPath` is set: unset it and move those hooks into `lefthook-local.yml`, which lefthook merges and git should ignore. If lefthook can't fetch the remote (offline, wrong tag) it says "Couldn't sync" and carries on without these hooks, so check that `lefthook dump` lists them. Project-only jobs can still go in the project's `lefthook.yml` beside `remotes:`.

6. **Agent guide.** Copy `templates/AGENTS-go-style.md` into `AGENTS.md`, replacing `<project>`. The Claude Code lint-on-edit hook is user-level (`~/.claude/settings.json`), so nothing per project is needed.

## Changing go-ci

A release is one commit tagged `v1.x.y`:

1. In `.github/workflows/go.yml`, set both `gaius-codius/go-ci/actions/...@` references to the new tag, so a project pinning this commit gets the actions from the same release. CI checks this when the tag is pushed.
2. Commit, tag `v1.x.y`, push the commit and the tag together (`git push --atomic origin main v1.x.y`), and move `v1` to it (a convenience for reading; projects pin SHAs). The release commit's `go-workflow` job can only resolve the new action references once the tag exists. If the release commit goes through a pull request instead, that PR's `go-workflow` check (and the run on the merge to `main`) fails to resolve `@v1.x.y`. That failure is expected, and the run for the tag push is the one that counts.
3. Never move or delete a `v1.x.y` tag. A repository ruleset ("Release tags") rejects updates and deletions of `v1.*` tags; it doesn't cover the moving `v1` tag.

A branch ruleset ("main checks") requires the `self-test` and `actions` checks before anything merges into `main`. `go-workflow / test-vet-build` isn't required, because a release commit fails it until its tag exists (step 2). Any other red `go-workflow` check still needs fixing before a merge. Repository admins bypass the ruleset, which the direct release push in step 2 relies on.

A change that would fail a project that passed before (a stricter gate, a new required input) is a new major version. CI runs `tests/test-govulncheck.sh` (the gate's pass/fail decisions against a fake scanner), `tests/test-drift.sh` (the drift check against a fake golangci-lint), shellcheck and actionlint.

CI also runs `go.yml` itself, on pull requests and on pushes, against a fixture module at this repository's root. The fixture is `go.mod`, the `fixture` package (with a fuzz target), `scripts/govulncheck-allow.txt`, and symlinks to `templates/mise.toml`, `baseline/.golangci.yml` and `baseline/scripts/`. Lint therefore runs with the pull request's baseline config. `go.yml` calls its drift and govulncheck actions at the last release, so a pull request that changes the baseline gets a drift warning there; a separate `actions` job runs this commit's actions and gate script against the same fixture. The fixture exists only for these runs; go-ci isn't a Go library. When you bump Go in `templates/mise.toml`, change the `toolchain` line in the root `go.mod` in the same commit (`go mod edit -toolchain=go<version>`), or the pinned-Go check fails. With mise activated in your shell, run `mise trust` once in a clone, because the root `mise.toml` makes mise refuse to run there until it's trusted.
