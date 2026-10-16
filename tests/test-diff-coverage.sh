#!/usr/bin/env bash
# Tests actions/diff-coverage/diff-coverage.sh against a throwaway Go module in a
# git repository, with coverage profiles from the real go test. Needs bash, git
# and go.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/actions/diff-coverage/diff-coverage.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git() { command git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

failures=0

# run_case <name> <MIN> <want exit 0|1> <expected substring> <unexpected substring or "">
# Commits a base module, applies the commands on stdin as the change, runs the
# tests for a profile, then runs the script with BASE=main.
run_case() {
  local name="$1" min="$2" want_code="$3" want="$4" unwanted="$5" out code
  rm -rf "${work}/repo" && mkdir -p "${work}/repo/sub" && cd "${work}/repo" || exit 1
  git init -q
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  printf 'package sub\n\nfunc Old(x int) int {\n\treturn x + 1\n}\n' >sub/sub.go
  printf 'package sub\n\nimport "testing"\n\nfunc TestOld(t *testing.T) {\n\tif Old(1) != 2 {\n\t\tt.Fatal("Old")\n\t}\n}\n' >sub/sub_test.go
  git add -A && git commit -qm base && git switch -qc change
  bash -s
  git add -A && git commit -qm change --allow-empty
  go test -coverprofile=coverage.out ./... >/dev/null 2>&1 || echo "(go test failed)"
  out="$(BASE=main MIN="${min}" GITHUB_STEP_SUMMARY="${work}/summary" "${script}" 2>&1)"
  code=$?
  [[ -f "${work}/summary" ]] && out+=$'\n'"$(cat "${work}/summary")" && rm -f "${work}/summary"
  cd "${work}" || exit 1
  if [[ ${want_code} -eq 0 && ${code} -ne 0 ]] || [[ ${want_code} -ne 0 && ${code} -eq 0 ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  elif [[ "${out}" != *"${want}"* ]] || [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# Two new functions, lines 7-9 and 11-13 (each block runs from the func line to
# its closing brace); only Half is tested.
two_funcs="printf '\nfunc Half(x int) int {\n\treturn x / 2\n}\n\nfunc Twice(x int) int {\n\treturn x * 2\n}\n' >>sub/sub.go
printf '\nfunc TestHalf(t *testing.T) {\n\tif Half(4) != 2 {\n\t\tt.Fatal(\"Half\")\n\t}\n}\n' >>sub/sub_test.go"

run_case "no change passes" 80 0 "no changed code lines" "::error" <<<":"
run_case "comment-only change passes" 80 0 "no changed code lines" "::error" <<<"printf '// A comment.\n' >>sub/sub.go"
run_case "covered change passes" 80 0 "1 of 1 changed code lines are covered" "::warning" \
  <<<"sed -i 's/x + 1/x + 2 - 1/' sub/sub.go"
run_case "uncovered line is warned" 0 0 "file=sub/sub.go,line=11,endLine=13,title=diff coverage" "" <<<"${two_funcs}"
run_case "half covered passes at 50" 50 0 "3 of 6 changed code lines are covered by tests (50.0%; minimum 50%)" "::error" <<<"${two_funcs}"
run_case "half covered fails at 80" 80 1 "below the minimum of 80%" "" <<<"${two_funcs}"
run_case "summary lists uncovered ranges" 0 0 '- `sub/sub.go:11-13`' "" <<<"${two_funcs}"
run_case "test-file changes don't count" 80 0 "no changed code lines" "" \
  <<<"printf '\nfunc TestMore(t *testing.T) {}\n' >>sub/sub_test.go"
run_case "bad minimum fails" abc 1 "must be a percentage" "" <<<":"
run_case "missing base fails" 80 1 "could not diff against main" "" <<<"git branch -qm main old"

# A missing profile, run directly.
cd "${work}/repo" || exit 1
if out="$(BASE=main MIN=80 PROFILE=nope.out "${script}" 2>&1)"; then
  echo "FAIL missing profile fails: exit 0"
  failures=$((failures + 1))
elif [[ "${out}" != *"coverage profile nope.out is missing"* ]]; then
  echo "FAIL missing profile fails: ${out}"
  failures=$((failures + 1))
else
  echo "ok   missing profile fails"
fi
cd "${work}" || exit 1

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all diff-coverage cases passed"
