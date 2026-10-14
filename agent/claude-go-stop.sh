#!/usr/bin/env bash
# Claude Code Stop / SubagentStop hook: when Go files changed against the merge-base,
# run deadcode over the module and report unreachable functions in the changed files.
# Advisory only: it never exits 2 and never blocks.
#
# Install: symlink it into ~/.claude/hooks/ and register it for both Stop and
# SubagentStop (go-ci README, "Claude Code Stop hook").
#
# Outcomes:
#   silent, exit 0: not in a git repo or Go module, nothing Go changed against the
#     merge-base, or deadcode found nothing in the changed files.
#   JSON additionalContext (hookSpecificOutput), exit 0: a report not delivered
#     before. On Stop this makes Claude continue the turn, so each distinct report is
#     delivered once.
#   JSON systemMessage, exit 0: the same report again. It shows to the user and does
#     not continue the turn, so the hook can't loop.
#   Reports are either findings or a tool failure (missing binary, crash); a failure
#   is never mistaken for "no findings" and never skipped silently.
#
# "Same report" is a sha256 of the checked tree (merge-base, diff, untracked files)
# plus the report text, remembered under the git dir. Without sha256sum or shasum
# nothing can be remembered, so every report goes out as systemMessage only.
set -uo pipefail

event=Stop

# emit <message> <fresh>: print the JSON for the hook and exit 0.
emit() {
  local m="go stop hook: $1" fresh=$2 field=systemMessage
  if [[ $fresh == 1 ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg m "$m" --arg e "$event" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
      exit 0
    fi
    field=additionalContext
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "$m" '{systemMessage: $m}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
    if [[ $field == additionalContext ]]; then
      printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$m"
    else
      printf '{"systemMessage":"%s"}\n' "$m"
    fi
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

# sha <stdin>: hex sha256 of stdin, or nothing when no tool is available.
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  fi
}

module_root() {
  local d=$1
  while :; do
    [[ -f $d/go.mod ]] && { printf '%s\n' "$d"; return 0; }
    [[ $d == / ]] && return 1
    d=$(dirname "$d")
  done
}

input=$(cat)
cwd=$PWD
if command -v jq >/dev/null 2>&1; then
  e=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null) && [[ -n $e ]] && event=$e
  c=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) && [[ -n $c ]] && cwd=$c
else
  c=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ -n $c ]] && cwd=$c
fi
[[ $event == Stop || $event == SubagentStop ]] || event=Stop

cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
root=$(module_root "$(pwd -P)") || exit 0
cd "$root" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# The merge-base with the default branch; the checked tree is the working tree.
base=""
for ref in origin/HEAD origin/main origin/master main master; do
  if base=$(git merge-base HEAD "$ref" 2>/dev/null) && [[ -n $base ]]; then break; fi
  base=""
done
if [[ -z $base ]]; then
  emit "could not find a merge-base with origin/main or main, so unreachable code was not checked." 0
fi

# Go files changed against the base, committed or not, paths relative to the module root.
changed=$({ git diff --relative --name-only "$base" -- . 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null; } |
  grep -E '\.go$|(^|/)go\.(mod|sum)$' | sort -u)
[[ -n $changed ]] || exit 0

tree=$({ printf '%s\n' "$base"; git diff --relative "$base" -- . 2>/dev/null
  git ls-files -o --exclude-standard 2>/dev/null | while IFS= read -r f; do printf '%s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"; done; } | sha)

out=$(run deadcode ./... 2>&1)
code=$?
if ((code != 0)); then
  report="deadcode failed (exit $code), so unreachable code was not checked: $out"
else
  # Existing dead code isn't this change's doing: keep findings in the changed files.
  report=$(awk -F: 'NR == FNR { c[$0]; next } { f = $1; sub(/^\.\//, "", f) } f in c' <(printf '%s\n' "$changed") <(printf '%s\n' "$out"))
  [[ -n $report ]] || exit 0
  report="deadcode reports unreachable functions in files you changed (advisory; remove them, or ignore if they are used in ways deadcode can't see, such as reflection or a library's public API):"$'\n'"$report"
fi

# Deliver each distinct report once as additionalContext; repeats go as systemMessage.
key=$(printf '%s\n%s' "$tree" "$report" | sha)
fresh=0
if [[ -n $key && -n $tree ]]; then
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || gitdir=""
  if [[ -n $gitdir ]] && mkdir -p "$gitdir/go-ci-stop-hook" 2>/dev/null; then
    seen="$gitdir/go-ci-stop-hook/delivered"
    if ! grep -qx "$key" "$seen" 2>/dev/null; then
      printf '%s\n' "$key" >>"$seen" 2>/dev/null && fresh=1
    fi
  fi
fi
emit "$report" "$fresh"
