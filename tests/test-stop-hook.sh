#!/usr/bin/env bash
# Tests agent/claude-go-stop.sh with fake hook-input JSON, a throwaway git repo with
# a Go module, and a fake deadcode (FAKE_DEAD_* select its behaviour).
# Needs bash, git, jq and sha256sum (or shasum).
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-go-stop.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/missingbin" "${work}/crashbin"

cat >"${work}/bin/deadcode" <<'FAKE'
#!/usr/bin/env bash
# Prints FAKE_DEAD_OUT (one finding per line), like `deadcode ./...`.
[[ -n "${FAKE_DEAD_OUT:-}" ]] && printf '%s\n' "${FAKE_DEAD_OUT}"
exit 0
FAKE
cat >"${work}/missingbin/deadcode" <<'FAKE'
#!/usr/bin/env bash
echo "deadcode not found (install mise and run 'mise install')" >&2
exit 127
FAKE
cat >"${work}/crashbin/deadcode" <<'FAKE'
#!/usr/bin/env bash
echo "panic: boom" >&2
exit 2
FAKE
chmod +x "${work}"/bin/deadcode "${work}"/missingbin/deadcode "${work}"/crashbin/deadcode

failures=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# new_repo: module on main with a commit, then a feature branch with no changes yet.
new_repo() {
  r="${work}/repo"
  rm -rf "${r}" && mkdir -p "${r}/lib"
  git -C "${r}" init -q -b main
  printf 'module example.com/mod\n\ngo 1.22\n' >"${r}/go.mod"
  printf 'package lib\n\n// Add adds.\nfunc Add(a, b int) int { return a + b }\n' >"${r}/lib/lib.go"
  printf 'package lib\n\nfunc old() {}\n' >"${r}/lib/old.go"
  git -C "${r}" add -A && git -C "${r}" commit -qm base
  git -C "${r}" checkout -q -b feature
}

# run_case <name> <want exit> <want output substring or ""> <unwanted substring or "">
# Runs the hook in the current repo; HOOK_PATH overrides PATH, FAKE_DEAD_* set deadcode.
run_case() {
  local name="$1" want_code="$2" want="$3" unwanted="$4" out code
  out="$(jq -n --arg c "${r}" --arg e "${EVENT:-Stop}" '{hook_event_name: $e, cwd: $c}' |
    PATH="${HOOK_PATH:-${work}/bin:${PATH}}" "${hook}" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]] || [[ -n "${want}" && "${out}" != *"${want}"* ]] ||
    [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]] ||
    [[ -z "${want}" && -z "${unwanted}" && -n "${out}" && "${want_code}" == 0 && "${EXPECT_SILENT:-}" == 1 ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}; output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# silent <name>: expects exit 0 and no output at all.
silent() {
  EXPECT_SILENT=1 run_case "$1" 0 "" ""
  EXPECT_SILENT=
}

finding='lib/lib.go:4:6: unreachable func: Add'
new_repo
silent "nothing changed against the merge-base is silent"

printf 'package lib\n\n// Add adds.\nfunc Add(a, b int) int { return a + b }\n// New is new.\nfunc New() {}\n' >"${r}/lib/lib.go"
FAKE_DEAD_OUT="" silent "changed Go files with no findings are silent"
FAKE_DEAD_OUT="lib/old.go:3:6: unreachable func: old" silent "findings only in unchanged files are silent"

FAKE_DEAD_OUT="${finding}" run_case "finding is delivered as additionalContext and (not systemMessage)" 0 '"additionalContext": "go stop hook: deadcode reports' "systemMessage"
FAKE_DEAD_OUT="${finding}" run_case "identical repeat is systemMessage only" 0 '"systemMessage"' "additionalContext"
FAKE_DEAD_OUT="${finding}" EVENT=SubagentStop run_case "repeat for SubagentStop is systemMessage too" 0 '"systemMessage"' "additionalContext"

printf '// more\n' >>"${r}/lib/lib.go"
FAKE_DEAD_OUT="${finding}" run_case "same report on a changed tree is delivered again" 0 '"additionalContext"' ""
FAKE_DEAD_OUT="lib/lib.go:6:6: unreachable func: New" run_case "a different report is delivered again" 0 '"additionalContext"' ""

new_repo
printf 'package lib\n\nfunc Extra() {}\n' >"${r}/lib/extra.go"
FAKE_DEAD_OUT="lib/extra.go:3:6: unreachable func: Extra" EVENT=SubagentStop run_case "untracked Go file counts; SubagentStop event is echoed" 0 '"hookEventName": "SubagentStop"' ""

new_repo
printf 'package lib\n\nfunc Extra() {}\n' >"${r}/lib/extra.go"
git -C "${r}" add -A && git -C "${r}" commit -qm extra
FAKE_DEAD_OUT="lib/extra.go:3:6: unreachable func: Extra" run_case "committed change against the merge-base counts" 0 '"additionalContext"' ""

new_repo
printf '# notes\n' >"${r}/NOTES.md"
silent "a non-Go change is silent"

new_repo
printf 'package lib\n\nfunc Extra() {}\n' >"${r}/lib/extra.go"
HOOK_PATH="${work}/missingbin:${work}/bin:${PATH}" run_case "missing deadcode is reported, not blocking" 0 "deadcode failed (exit 127)" ""
HOOK_PATH="${work}/crashbin:${work}/bin:${PATH}" run_case "deadcode crash is reported as a failure, not as findings" 0 "panic: boom" "reports unreachable"
HOOK_PATH="${work}/crashbin:${work}/bin:${PATH}" run_case "identical failure repeat is systemMessage only" 0 '"systemMessage"' "additionalContext"

d="${work}/nogit"
mkdir -p "${d}" && printf 'module x\n' >"${d}/go.mod"
r="${d}"
silent "a module outside git is silent"
r="${work}"
silent "a directory outside any module is silent"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
