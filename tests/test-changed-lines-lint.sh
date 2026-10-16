#!/usr/bin/env bash
# Tests actions/changed-lines-lint/changed-lines-lint.sh against a fake
# golangci-lint that prints canned JSON, in a throwaway git repository with a
# merge base. Needs bash, git and jq only.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/actions/changed-lines-lint/changed-lines-lint.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin" "${work}/repo"
cat >"${work}/bin/golangci-lint" <<'FAKE'
#!/usr/bin/env bash
# Prints ${FAKE_JSON} and exits with ${FAKE_CODE}.
printf '%s\n' "${FAKE_JSON}"
exit "${FAKE_CODE:-0}"
FAKE
chmod +x "${work}/bin/golangci-lint"

(
  cd "${work}/repo" &&
    git init -q -b main &&
    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base &&
    printf 'module example.com/m\n\ngo 1.24\n' >go.mod &&
    git add go.mod &&
    git -c user.name=t -c user.email=t@t commit -q -m change
) || {
  echo "could not set up the git repository"
  exit 1
}

# issue <path> <linter> <text>: one golangci-lint JSON issue.
issue() {
  jq -cn --arg f "$1" --arg l "$2" --arg t "$3" \
    '{FromLinter: $l, Text: $t, Pos: {Filename: $f, Line: 7, Column: 2}}'
}
# issues <issue>...: a golangci-lint JSON report.
issues() {
  local IFS=,
  printf '{"Issues":[%s],"Report":{}}' "$*"
}

own_func="$(issue a.go wrapcheck 'error returned from external package is unwrapped: sig: func example.com/m/internal/config.CheckShares(path string) error')"
own_method="$(issue a.go wrapcheck 'error returned from external package is unwrapped: sig: func (*example.com/m/sub.T).M() error')"
own_iface="$(issue a.go wrapcheck 'error returned from interface method should be wrapped: sig: func (example.com/m.I).M() error')"
own_root="$(issue a.go wrapcheck 'error returned from external package is unwrapped: sig: func example.com/m.A() error')"
other_mod="$(issue a.go wrapcheck 'error returned from external package is unwrapped: sig: func example.com/mm.A() error')"
in_test="$(issue a_test.go wrapcheck 'error returned from external package is unwrapped: sig: func os.ReadFile(name string) ([]byte, error)')"
stdlib="$(issue a.go wrapcheck 'error returned from external package is unwrapped: sig: func os.ReadFile(name string) ([]byte, error)')"
cognit="$(issue 'dir,x/b.go' gocognit 'cognitive complexity 31 of func `f` is high (> 30)')"

failures=0

# run_case <name> <want exit> <base> <expected output substring> <unexpected substring or "">
# FAKE_JSON and FAKE_CODE come from the environment.
run_case() {
  local name="$1" want_code="$2" base="$3" want="$4" unwanted="$5" out code
  out="$(cd "${work}/repo" && PATH="${work}/bin:${PATH}" BASE="${base}" LINTERS=gocognit,wrapcheck "${script}" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}; output:"
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

FAKE_JSON="$(issues)" FAKE_CODE=0 \
  run_case "no findings passes" 0 HEAD~1 "changed lines: no findings" "::error"
FAKE_JSON='{"Issues":null,"Report":{}}' FAKE_CODE=0 \
  run_case "null issues passes" 0 HEAD~1 "changed lines: no findings" "::error"
FAKE_JSON="$(issues "${cognit}")" FAKE_CODE=1 \
  run_case "gocognit finding fails" 1 HEAD~1 "::error file=dir%2Cx/b.go,line=7,col=2,title=gocognit::cognitive complexity 31" "no findings"
FAKE_JSON="$(issues "${cognit}")" FAKE_CODE=1 \
  run_case "finding has a plain line" 1 HEAD~1 'dir,x/b.go:7:2: cognitive complexity 31 of func `f` is high (> 30) (gocognit)' ""
FAKE_JSON="$(issues "${own_func}" "${own_method}" "${own_iface}" "${own_root}")" FAKE_CODE=1 \
  run_case "wrapcheck on own module is dropped" 0 HEAD~1 "ignored 4 wrapcheck findings" "::error"
FAKE_JSON="$(issues "${in_test}")" FAKE_CODE=1 \
  run_case "wrapcheck in a test is dropped" 0 HEAD~1 "ignored 1 wrapcheck findings" "::error"
FAKE_JSON="$(issues "${stdlib}" "${own_func}")" FAKE_CODE=1 \
  run_case "wrapcheck on stdlib is kept" 1 HEAD~1 "title=wrapcheck::error returned from external package is unwrapped: sig: func os.ReadFile" "CheckShares"
FAKE_JSON="$(issues "${other_mod}")" FAKE_CODE=1 \
  run_case "wrapcheck on a module sharing the prefix is kept" 1 HEAD~1 "example.com/mm.A" "ignored"
FAKE_JSON="$(issues "${cognit}")" FAKE_CODE=1 \
  run_case "no merge base warns and passes" 0 nosuchref "::warning title=changed lines::changed lines were not linted (no merge base with nosuchref)" "::error"
FAKE_JSON="panic: boom" FAKE_CODE=3 \
  run_case "tool crash fails" 1 HEAD~1 "golangci-lint failed (exit 3)" "no findings"
FAKE_JSON='{"Issues":[' FAKE_CODE=1 \
  run_case "malformed JSON fails" 1 HEAD~1 "could not parse golangci-lint's JSON output" "no findings"
FAKE_JSON='' FAKE_CODE=0 \
  run_case "empty output fails" 1 HEAD~1 "could not parse golangci-lint's JSON output" "no findings"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all changed-lines-lint cases passed"
