#!/usr/bin/env bash
# Claude Code PostToolUse hook: after an agent edits a .go file in a Go module,
# format the file, then check the whole module still builds and vets, and lint the
# file's package with the module's .golangci.yml (the go-ci baseline).
#
# Install: symlink it into ~/.claude/hooks/ and register it for Edit|Write|MultiEdit
# (see go-style/SKILL.md in gaius-codius/skills).
#
# Outcomes:
#   exit 2, findings on stderr: the check ran and found problems (Claude Code feeds
#     them back to the agent). Build and type errors are reported wherever they are,
#     since an edit can break callers in files it never touched; vet and lint
#     warnings are limited to the edited file.
#   exit 0, nothing: not a Go edit, or no go.mod above the file.
#   exit 0 with JSON additionalContext on stdout: the check could not run (a missing
#     tool, a failed dependency fetch, a module without .golangci.yml). Never silent.
set -uo pipefail

# say <message>: tell the agent something without blocking, then exit 0.
say() {
  local m=$1
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "go edit hook: $m" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"go edit hook: %s"}}\n' "$m"
  fi
  exit 0
}

# run <cmd>...: tools are pinned in the module's mise.toml; fall back to mise
# when they are not on PATH. Returns 127 when neither works.
run() {
  if command -v "$1" >/dev/null 2>&1; then "$@"
  elif command -v mise >/dev/null 2>&1; then mise exec -- "$@"
  else echo "$1 not found (install mise and run 'mise install')" >&2; return 127
  fi
}

# module_root <dir>: the nearest directory at or above <dir> with go.mod.
module_root() {
  local d=$1
  while :; do
    [[ -f $d/go.mod ]] && { printf '%s\n' "$d"; return 0; }
    [[ $d == / ]] && return 1
    d=$(dirname "$d")
  done
}

# tool_failed <output>: true when go output has "go: ..." lines (module and fetch
# problems) and no file:line diagnostics, so the code itself wasn't judged.
tool_failed() {
  grep -q '^go: ' <<<"$1" && ! grep -Eq '\.go:[0-9]+' <<<"$1"
}

input=$(cat)
if command -v jq >/dev/null 2>&1; then
  if ! file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty'); then
    say "could not read the hook input with jq, so this edit was not checked."
  fi
  parsed=1
else
  # Best effort without jq, only to decide whether the edit is ours to report on.
  file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  parsed=0
fi
[[ $file == *.go && -f $file ]] || exit 0
file=$(realpath -- "$file")

root=$(module_root "$(dirname "$file")") || exit 0
if [[ ! -f $root/.golangci.yml ]]; then
  say "lint skipped for $file: $root has go.mod but no .golangci.yml. This checkout may predate go-ci; adopt the baseline (go-ci README, 'Adopting it'). Build and vet were not run either."
fi
if ((!parsed)); then
  say "jq is not on PATH, so the edited path can't be read reliably and this edit was not checked."
fi
cd "$root" || say "cannot cd to $root, so this edit was not checked."

rel=$(realpath --relative-to=. "$file")
pkg="./$(dirname "$rel")"
findings=""
add() { findings+="$1"$'\n'; }

# Format first; a failure here is a tool problem unless the file doesn't parse.
if ! out=$(run golangci-lint fmt "$rel" 2>&1); then
  code=$?
  if ((code == 127)) || ! grep -Eq '\.go:[0-9]+' <<<"$out"; then
    say "golangci-lint fmt failed (exit $code), so formatting, lint, build and vet were not run: $out"
  fi
  add "$out"
fi

# Build the whole module: an edit can break callers in other packages.
if ! out=$(run go build ./... 2>&1); then
  code=$?
  if ((code == 127)) || tool_failed "$out"; then
    say "go build could not run (exit $code), so build, vet and lint were not run: $out"
  fi
  add "go build ./... failed:"$'\n'"$out"
else
  # Vet compiles tests too. Type errors ("vet: ...") are always reported; the
  # other diagnostics only for the edited file.
  out=$(run go vet ./... 2>&1)
  code=$?
  if ((code == 127)) || { ((code != 0)) && tool_failed "$out"; }; then
    say "go vet could not run (exit $code), so vet and lint were not run: $out"
  fi
  if ((code != 0)); then
    kept=$(grep -E "^vet: |^(\./)?${rel//./\\.}:" <<<"$out")
    [[ -n $kept ]] && add "go vet ./...:"$'\n'"$kept"
  fi

  # Lint the edited package; keep findings in the edited file.
  if ! command -v jq >/dev/null 2>&1; then
    say "jq is not on PATH, so lint results can't be filtered; lint was not run."
  fi
  json=$(run golangci-lint run --output.json.path=stdout --output.text.path= --show-stats=false "$pkg" 2>/dev/null)
  code=$?
  if ((code > 1)) || ! jq -e '.Issues' >/dev/null 2>&1 <<<"$json"; then
    say "golangci-lint run failed (exit $code), so lint was not checked for $rel."
  fi
  kept=$(jq -r --arg f "$rel" '.Issues[] | select(.Pos.Filename == $f) | "\(.Pos.Filename):\(.Pos.Line):\(.Pos.Column): \(.Text) (\(.FromLinter))"' <<<"$json")
  [[ -n $kept ]] && add "golangci-lint:"$'\n'"$kept"
fi

if [[ -n $findings ]]; then
  printf '%s' "$findings" >&2
  exit 2
fi
exit 0
