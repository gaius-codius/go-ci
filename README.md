# go-ci

Shared quality setup for gaius-codius Go projects: one reusable CI workflow, a vulnerability gate, a baseline golangci-lint config, shared git hooks, and templates. Projects pin a release by commit SHA and keep their own allowlist and release jobs. The Go module must be at the repository root.

| Piece | Where | How a project uses it |
|---|---|---|
| Reusable workflow | `.github/workflows/go.yml` | Called from the project's `ci.yml` |
| govulncheck gate | `actions/govulncheck`, `baseline/scripts/govulncheck.sh` | Run by the workflow; the project keeps a copy of the script for local runs and its own `scripts/govulncheck-allow.txt` |
| Baseline drift check | `actions/baseline-drift` | Run by the workflow; warns, never fails |
| Silenced-checks report | `actions/silenced-checks` | Run by the workflow on pull requests; warns, never fails |
| Diff-coverage gate | `actions/diff-coverage` | Run by the workflow on pull requests when `diff-coverage` is set |
| Lint config | `baseline/.golangci.yml` | Copied to the project root (golangci-lint can't load a remote config) |
| Lint helper | `baseline/scripts/lint-packages.sh` | Copied to `scripts/`; the hooks call it |
| Git hooks | `lefthook/go.yml` | Loaded through lefthook `remotes:`, pinned to a tag |
| Toolchain pins | `templates/mise.toml` | Copied once; Renovate keeps them current |
| gopls (language server) | `templates/mise.toml` | Pinned with the other tools so editors and agents (Claude Code's `LSP` tool) use the version the project expects; CI doesn't install it |
| Agent guide section | `templates/AGENTS-go-style.md` | Copied into the project's `AGENTS.md` |
| Agent permission rules | `agent/claude-settings.json` | Merged into the project's `.claude/settings.json` |
| Update policy | `renovate/go.json5` | Extended from the project's `renovate.json5` |

## What the workflow checks

In order, on the runner the caller names. Steps marked *PR* run only on `pull_request` events and look only at what the pull request changes (base branch...HEAD; the checkout fetches full history for them):

1. Go from `mise.toml` is the Go that runs, and `go.mod`'s `toolchain` line matches it.
2. Drift from this baseline (warnings only).
3. *PR* Silenced checks: a warning and a job-summary table for each added `//nolint`, `#nosec`, `//lint:ignore` or test `.Skip(`, each changed line of `.golangci.yml`, and each new ID in the govulncheck allowlist, so a person reviews it. Never fails.
4. *PR* Dependency review (`actions/dependency-review-action`, report only): lists added modules with their OpenSSF Scorecard and known vulnerabilities, so a misspelled or invented module stands out. With `dependency-review: auto` it runs in public repositories only, because private ones need GitHub Advanced Security.
5. `go mod tidy -diff`, if `tidy-check` is on.
6. `gorelease`, if `gorelease` is on: API changes since the latest release tag and the version it suggests, in the job summary; incompatible changes are a warning, never a failure. It runs before the tests because it refuses a tree with untracked files. For library modules; it fetches the base version from the module proxy, so a private module needs `GOPRIVATE` and credentials.
7. `shellcheck -S warning` on the `shellcheck` paths, if any.
8. `go test -race -shuffle=on` in one run, with a coverage summary in the job summary (a trend, not a gate).
9. *PR* Diff coverage, if `diff-coverage` is above 0: fails when fewer than that percentage of changed code lines (in non-test `.go` files) are covered. A line counts when it holds code, and is covered when every coverage block on it ran. Uncovered ranges get a warning and are listed in the job summary.
10. Fuzz targets, if the caller lists any, for `fuzz-time` each.
11. `go vet`, `golangci-lint run`.
12. *PR* The `new-code-linters` (default gocognit, nestif, wrapcheck) on changed lines only, with `golangci-lint --new-from-merge-base`, so existing code doesn't fail. A finding is reported on the line the linter names: a new function that is too complex fails, an existing function that grows does only when its `func` line changes.
13. The govulncheck gate: any reachable vulnerability not in the allowlist fails.
14. `go build` of the `build` package (or `./...`).
15. `deadcode ./...`, if `deadcode` is on: a warning and a job-summary report, never a failure.
16. `nilaway`, if `nilaway` is on: possible nil dereferences in the module's packages as a warning and a job-summary report, never a failure.
17. Mutation testing with `gremlins`, if `mutation` is on: test efficacy and the mutants no test caught, in the job summary; never a failure. It reruns the tests once per mutant, so turn it on for scheduled or manual runs (below). gremlins 0.5 needs the `module` line first in `go.mod`, and the step warns instead of running when it isn't.

The job stops after `timeout-minutes`. The workflow tells mise to skip gopls (an editor tool, and mise builds it from source), and also each optional tool (deadcode, shellcheck, nilaway, gorelease, gremlins) unless its input is on.

Inputs:

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
| `shellcheck` | `""` (off) | Space- or newline-separated paths or globs of scripts to check; needs `shellcheck` in `mise.toml` (in the template) |
| `deadcode` | `false` | Report unreachable functions; needs `deadcode` in `mise.toml` (in the template). Reports only, and only finds code unreachable from `main` packages |
| `new-code-linters` | `gocognit,nestif,wrapcheck` | Linters pull requests must pass on changed lines; `""` turns it off. Their settings come from `.golangci.yml` |
| `dependency-review` | `auto` | `auto` (public repositories), `true` or `false` |
| `diff-coverage` | `0` (off) | Minimum percentage of changed code lines covered by tests |
| `nilaway` | `false` | Report possible nil dereferences; needs `nilaway` in `mise.toml` (in the template) |
| `gorelease` | `false` | Report API changes for a library module; needs `gorelease` in `mise.toml` (in the template) |
| `mutation` | `false` | Run gremlins mutation testing; needs `gremlins` in `mise.toml` (in the template) |

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

   In `.golangci.yml`, set `formatters.settings.goimports.local-prefixes` and `linters.settings.wrapcheck.ignore-package-globs` to the module path. Decide how errors are wrapped: the baseline doesn't check `%w` against `%v` (`errorlint` `errorf: false`). An app, or code under `internal/`, can set `errorf: true` to require `%w`, since no outside module can come to depend on its inner errors; a public library uses `%w` only for errors it supports as part of its API and `%v` where it hides a dependency. The drift check compares only which linters are enabled, so settings like this aren't drift. Add project exclusions (for example gosec `G204`) with a reason. Create `scripts/govulncheck-allow.txt`; it may hold only comments:

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

   To run mutation testing weekly and on demand, add `schedule:` (for example `- cron: '17 3 * * 1'`) and `workflow_dispatch:` to the project's `on:` and pass `mutation: ${{ github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' }}`.

   Pin the full commit SHA of a release tag (`git ls-remote --tags https://github.com/gaius-codius/go-ci 'v1.*'`), as for any third-party action: the workflow runs on your runner with your checkout. Renovate keeps the pin current (step 7). The status check is then named `verify / test-vet-build`. Release jobs stay in the project and can keep `needs: verify`. Steps that only one project needs (an extra package, a service) go in a separate job in the project's `ci.yml`.

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

   then `lefthook install`. Lefthook fetches a remote once per ref, so `ref` moves with the CI pin; Renovate bumps both in one PR (step 7), after which run `lefthook install` again. It refuses to install while `core.hooksPath` is set: unset it and move those hooks into `lefthook-local.yml`, which lefthook merges and git should ignore. If lefthook can't fetch the remote (offline, wrong tag) it says "Couldn't sync" and carries on without these hooks, so check that `lefthook dump` lists them. Project-only jobs can still go in the project's `lefthook.yml` beside `remotes:`.

6. **Agent guide and permissions.** Copy `templates/AGENTS-go-style.md` into `AGENTS.md`, replacing `<project>` and stating the project's `%w`/`%v` policy (step 2). Merge `agent/claude-settings.json` into the project's `.claude/settings.json`, so Claude Code can't edit `.golangci.yml` or the govulncheck allowlist; a person makes those changes. Change the allowlist path there if the project's `govulncheck-allowlist` input does. The rules anchor at the project root and cover Claude Code's file tools and the file commands it recognizes in Bash (`sed`, `tee`, redirections), not a script that writes the file itself, so the silenced-checks step in CI is the backstop. The Claude Code hooks are user-level (`~/.claude/settings.json`), so nothing else per project is needed.

7. **Version updates.** Delete `.github/dependabot.yml`. In the repo's settings, keep Dependabot alerts on (Renovate reads them to open security PRs outside the schedule, for indirect dependencies too) and turn Dependabot security updates off, or both bots propose the same fix. Then add `renovate.json5`:

   ```json5
   {
     $schema: 'https://docs.renovatebot.com/renovate-schema.json',
     extends: ['github>gaius-codius/go-ci//renovate/go.json5'],
   }
   ```

   Check it with `npx --yes --package renovate -- renovate-config-validator --strict --no-global renovate.json5`, then add the repo to the Renovate GitHub App's selected repositories. Renovate opens a Dependency Dashboard issue listing every dependency it found and every pending update. The preset ([`renovate/go.json5`](renovate/go.json5)) runs weekly (Monday before 04:00 UTC) and groups updates into one PR each for:

   | PR | What it bumps |
   |---|---|
   | Go modules | `go.mod` requirements, minor and patch (each major gets its own PR, with import paths rewritten) |
   | GitHub Actions | `uses:` pins, as commit SHAs with the version in a comment (majors in a second grouped PR) |
   | mise tools | `mise.toml` tools other than Go (golangci-lint, govulncheck, deadcode, gopls, shellcheck, nilaway, gorelease, gremlins, jq, lefthook), majors included |
   | Go toolchain | Go in `mise.toml` and the `go.mod` `toolchain` line, together, since CI requires them to match |
   | go-ci | The `go.yml` SHA pin in `ci.yml` and the `lefthook.yml` remotes `ref`, together |

   It never changes the `go` directive in `go.mod`: that is the module's minimum Go, and it moves by hand or when a dependency needs it. Project-specific rules go in the project's `renovate.json5` after `extends`.

## Claude Code edit hook

`agent/claude-go-lint-on-edit.sh` runs after Claude Code edits a `.go` file. In a module with `.golangci.yml` it formats the file, runs `go build ./...` and `go vet ./...` over the whole module (an edit can break callers in packages it never touched), and lints the file's package. Build and type errors are reported wherever they are; vet and lint findings only for the edited file. Findings go to stderr with exit 2, which Claude Code feeds back to the agent.

It never skips silently. When the check can't run (a missing tool, a failed dependency fetch, a module with `go.mod` but no `.golangci.yml`), it exits 0 with a `PostToolUse` `additionalContext` message saying so. Non-Go files and files outside a Go module exit 0 immediately.

Install once per machine, from a clone of this repo:

```sh
mkdir -p ~/.claude/hooks
ln -sf "$GOCI/agent/claude-go-lint-on-edit.sh" ~/.claude/hooks/go-lint-on-edit.sh
```

and register it in `~/.claude/settings.json` under `hooks.PostToolUse`:

```json
{
  "matcher": "Edit|Write|MultiEdit",
  "hooks": [
    { "type": "command", "command": "\"$HOME\"/.claude/hooks/go-lint-on-edit.sh", "timeout": 120 }
  ]
}
```

## Claude Code Stop hook

`agent/claude-go-stop.sh` runs when Claude Code finishes a turn (`Stop`) or a subagent finishes (`SubagentStop`). If Go files changed against the merge-base with `origin/main` (or `main`), committed or not, it runs `deadcode ./...` and reports unreachable functions in the files that changed, so dead code already in the module doesn't nag. It is advisory: it never exits 2 and never blocks. It stays silent when nothing Go changed, outside a git repository or Go module, or when deadcode finds nothing in the changed files.

A tool failure (deadcode missing, a crash) is reported as a failure, never as "no findings", and never skipped silently. On `Stop`, `additionalContext` makes Claude continue the turn, so each distinct report is delivered that way once. It is keyed on a hash of the checked tree (merge-base, diff, untracked files) plus the report text, kept in `go-ci-stop-hook/` under the git dir. An identical repeat goes out only as `systemMessage`, which shows to you and doesn't continue the turn, so the hook can't loop. Tests: `tests/test-stop-hook.sh`.

Install once per machine, beside the edit hook:

```sh
ln -sf "$GOCI/agent/claude-go-stop.sh" ~/.claude/hooks/go-stop.sh
```

and register it in `~/.claude/settings.json` under both `hooks.Stop` and `hooks.SubagentStop`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME\"/.claude/hooks/go-stop.sh", "timeout": 120 }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME\"/.claude/hooks/go-stop.sh", "timeout": 120 }] }
    ]
  }
}
```

It needs `deadcode` from the project's `mise.toml` (the template pins it). deadcode only finds code unreachable from `main` packages, so a pure library reports little.

## Changing go-ci

A release is one commit tagged `v1.x.y`:

1. In `.github/workflows/go.yml`, set every `gaius-codius/go-ci/actions/...@` reference to the new tag, so a project pinning this commit gets the actions from the same release. CI checks this when the tag is pushed.
2. Commit, tag `v1.x.y`, push the commit and the tag together (`git push --atomic origin main v1.x.y`), and move `v1` to it (a convenience for reading; projects pin SHAs). The release commit's `go-workflow` job can only resolve the new action references once the tag exists. If the release commit goes through a pull request instead, that PR's `go-workflow` check (and the run on the merge to `main`) fails to resolve `@v1.x.y`. That failure is expected, and the run for the tag push is the one that counts.
3. Never move or delete a `v1.x.y` tag. A repository ruleset ("Release tags") rejects updates and deletions of `v1.*` tags; it doesn't cover the moving `v1` tag.

A branch ruleset ("main checks") requires the `self-test` and `actions` checks before anything merges into `main`. `go-workflow / test-vet-build` isn't required, because a release commit fails it until its tag exists (step 2). Any other red `go-workflow` check still needs fixing before a merge. Repository admins bypass the ruleset, which the direct release push in step 2 relies on.

Projects load `renovate/go.json5` from `main`, not from a release, so a change to it applies to every project at its next Renovate run once merged, without a tag. Check it first with `npx --yes --package renovate -- renovate-config-validator --strict --no-global renovate/go.json5`. Because of that reach, change it only through a pull request, so the "main checks" ruleset above runs first.

A change that would fail a project that passed before (a stricter gate, a new required input) is a new major version. CI runs `tests/test-govulncheck.sh` (the gate's pass/fail decisions against a fake scanner), `tests/test-drift.sh` (the drift check against a fake golangci-lint), `tests/test-silenced.sh` and `tests/test-diff-coverage.sh` (the pull-request checks against throwaway git repositories), `tests/test-hook.sh` and `tests/test-stop-hook.sh` (the Claude Code hooks against fake tools), shellcheck and actionlint.

CI also runs `go.yml` itself, on pull requests and on pushes, against a fixture module at this repository's root. The fixture is `go.mod`, the `fixture` package (with a fuzz target), `scripts/govulncheck-allow.txt`, and symlinks to `templates/mise.toml`, `baseline/.golangci.yml` and `baseline/scripts/`. Lint therefore runs with the pull request's baseline config. `go.yml` calls its own actions at the last release, so a pull request that changes the baseline gets a drift warning there; a separate `actions` job runs this commit's actions and gate script against the same fixture. A new action can't run from `go.yml` until a release contains it, so a pull request that adds one is a release pull request (step 2). The fixture exists only for these runs; go-ci isn't a Go library. When you bump Go in `templates/mise.toml`, change the `toolchain` line in the root `go.mod` in the same commit (`go mod edit -toolchain=go<version>`), or the pinned-Go check fails. With mise activated in your shell, run `mise trust` once in a clone, because the root `mise.toml` makes mise refuse to run there until it's trusted.
