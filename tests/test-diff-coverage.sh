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

# run_case <name> <MIN> <want exit 0|1> <expected substring> <unexpected substring or ""> [env args...]
# Commits a base module, applies the commands on stdin as the change, runs the
# tests for a profile, runs the commands in ${after_test} if set (to doctor the
# profile), then runs the script with BASE=main from ${case_dir:-.} through env
# with the extra args (VAR=value overrides, -u VAR unsets).
run_case() {
  local name="$1" min="$2" want_code="$3" want="$4" unwanted="$5" out code
  shift 5
  rm -rf "${work}/repo" && mkdir -p "${work}/repo/sub" && cd "${work}/repo" || exit 1
  git init -q
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  printf 'package sub\n\nfunc Old(x int) int {\n\treturn x + 1\n}\n' >sub/sub.go
  printf 'package sub\n\nimport "testing"\n\nfunc TestOld(t *testing.T) {\n\tif Old(1) != 2 {\n\t\tt.Fatal("Old")\n\t}\n}\n' >sub/sub_test.go
  git add -A && git commit -qm base && git switch -qc change
  bash -s
  git add -A && git commit -qm change --allow-empty
  go test -coverprofile=coverage.out ./... >/dev/null 2>&1 || echo "(go test failed)"
  [[ -z "${after_test:-}" ]] || bash -c "${after_test}"
  out="$(cd "${case_dir:-.}" && BASE=main MIN="${min}" GITHUB_STEP_SUMMARY="${work}/summary" env "$@" "${script}" 2>&1)"
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

# Two new functions, lines 7-9 and 11-13; only Half is tested. Go before 1.27
# starts a function's block on the func line, later ones on the first
# statement, so the cases don't depend on where a block starts.
two_funcs="printf '\nfunc Half(x int) int {\n\treturn x / 2\n}\n\nfunc Twice(x int) int {\n\treturn x * 2\n}\n' >>sub/sub.go
printf '\nfunc TestHalf(t *testing.T) {\n\tif Half(4) != 2 {\n\t\tt.Fatal(\"Half\")\n\t}\n}\n' >>sub/sub_test.go"

run_case "no change passes" 80 0 "no changed code lines" "::error" <<<":"
run_case "comment-only change passes" 80 0 "no changed code lines" "::error" <<<"printf '// A comment.\n' >>sub/sub.go"
run_case "covered change passes" 80 0 "1 of 1 changed code lines are covered" "::warning" \
  <<<"sed -i 's/x + 1/x + 2 - 1/' sub/sub.go"
run_case "uncovered line is warned" 0 0 ",endLine=13,title=diff coverage" "" <<<"${two_funcs}"
run_case "half covered passes at 50" 50 0 "changed code lines are covered by tests (50.0%; minimum 50%)" "::error" <<<"${two_funcs}"
run_case "half covered fails at 80" 80 1 "below the minimum of 80%" "" <<<"${two_funcs}"
run_case "summary lists uncovered ranges" 0 0 '- `sub/sub.go:1' "" <<<"${two_funcs}"
run_case "comments inside a function don't count" 80 0 "1 of 1 changed code lines" "" \
  <<<"sed -i 's|^\treturn x + 1|\t// One more.\n\n\treturn x + 2 - 1|' sub/sub.go"
run_case "test-file changes don't count" 80 0 "no changed code lines" "" \
  <<<"printf '\nfunc TestMore(t *testing.T) {}\n' >>sub/sub_test.go"
run_case "bad minimum fails" abc 1 "must be a percentage" "" <<<":"
run_case "minimum above 100 fails" 101 1 "must be a percentage" "" <<<":"
run_case "negative minimum fails" -1 1 "must be a percentage" "" <<<":"
run_case "empty minimum fails" "" 1 "::error title=diff coverage::MIN is empty" "" <<<":"
run_case "empty base fails" 80 1 "::error title=diff coverage::BASE is empty" "" BASE= <<<":"
run_case "unset base fails" 80 1 "::error title=diff coverage::BASE is empty" "" -u BASE <<<":"
run_case "missing base fails" 80 1 "could not diff against main" "" <<<"git branch -qm main old"
run_case "a multi-line error stays on the error line" 80 1 "could not diff against main%0Ax: " \
  $'\nx' BASE=$'main\nx' <<<":"
run_case "missing profile fails" 80 1 "coverage profile nope.out is missing" "" PROFILE=nope.out <<<":"
case_dir=sub run_case "running below the repository root fails" 80 1 "run this from the repository root" "" <<<":"

# Profiles that are broken or are for another module fail, even with nothing
# changed.
after_test="printf 'mode: set\ngarbage\n' >coverage.out" \
  run_case "garbage profile fails" 100 1 "coverage.out line 2 is not a coverage record: garbage" "" <<<":"
after_test="printf 'mode: sometimes\n' >coverage.out" \
  run_case "unknown profile mode fails" 100 1 "coverage.out is not a Go coverage profile" "" <<<":"
after_test="sed -i 's|^example.com/m/|example.com/other/|' coverage.out" \
  run_case "profile for another module fails" 100 1 "has no coverage records for module example.com/m" "" <<<"${two_funcs}"

# Exact boundaries; the percentage shown is rounded down. A, B and C are one
# line each, and only A and B are tested.
thirds="printf '\nfunc A() int { return 1 }\nfunc B() int { return 2 }\nfunc C() int { return 3 }\n' >>sub/sub.go
printf '\nfunc TestAB(t *testing.T) {\n\tif A()+B() != 3 {\n\t\tt.Fatal(\"AB\")\n\t}\n}\n' >>sub/sub_test.go"
run_case "full coverage passes at 100" 100 0 "1 of 1 changed code lines are covered by tests (100.0%; minimum 100%)" "::error" \
  <<<"sed -i 's/x + 1/x + 2 - 1/' sub/sub.go"
run_case "two thirds fails at 100" 100 1 "66.6%25 covered (2 of 3), below the minimum of 100%25" "" <<<"${thirds}"
run_case "two thirds fails at 66.7" 66.7 1 "66.6%25 covered (2 of 3), below the minimum of 66.7%25" "" <<<"${thirds}"
run_case "two thirds passes at 66.6" 66.6 0 "2 of 3 changed code lines are covered by tests (66.6%; minimum 66.6%)" "::error" <<<"${thirds}"

# File names git would quote or prefix differently, and ones with spaces, tabs,
# quotes or commas, are still read; each new function F is untested.
newf="printf 'package sub\n\nfunc F() int {\n\treturn 1\n}\n'"
run_case "non-ASCII file name is read" 100 1 "file=sub/é.go,line=" "" <<<"${newf} >sub/é.go"
run_case "diff.noprefix is ignored" 100 1 "file=sub/new.go,line=" "" \
  <<<"git config diff.noprefix true && ${newf} >sub/new.go"
run_case "diff.mnemonicPrefix is ignored" 100 1 "file=sub/new.go,line=" "" \
  <<<"git config diff.mnemonicPrefix true && ${newf} >sub/new.go"
run_case "file name with a space is read" 100 1 "file=sub/my file.go,line=" "" <<<"${newf} >'sub/my file.go'"
run_case "summary lists a file name with a space" 0 0 '- `sub/my file.go:' "" <<<"${newf} >'sub/my file.go'"
run_case "file name with a tab and a quote is read" 100 1 $'file=sub/t\tq"b.go,line=' "" \
  <<<"${newf} >\$'sub/t\\tq\"b.go'"
run_case "comma in a file name is escaped" 100 1 "file=sub/a%2Cb.go,line=" "" <<<"${newf} >sub/a,b.go"

# An added line starting with "++ " (here in a raw string) is not a file header.
run_case "added ++ line is not a header" 80 1 "file=sub/sub.go,line=" "no changed code lines" \
  <<<"printf '\nvar banner = \`\n++ banner\n\`\n\nfunc Twice(x int) int {\n\treturn x * 2\n}\n' >>sub/sub.go"

# Block comments inside a function don't count; code after one on a line does.
run_case "block comments don't count" 80 0 "1 of 1 changed code lines" "" \
  <<<"sed -i 's|^\treturn x + 1|\t/*\n\t * One more.\n\tstill a comment\n\t*/\n\treturn x + 2 - 1|' sub/sub.go"
run_case "code after a block comment counts" 80 0 "2 of 2 changed code lines" "" \
  <<<"sed -i 's|^\treturn x + 1|\t/* One */ x++\n\treturn x|' sub/sub.go"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all diff-coverage cases passed"
