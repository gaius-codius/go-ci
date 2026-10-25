#!/usr/bin/env bash
# Tests the "Mutation testing (gremlins)" step of .github/workflows/go.yml: takes
# the step's script out of the workflow and runs it with a stub gremlins that
# records its GOFLAGS and writes a given report. Needs bash, awk, jq and go.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The step's run block: the lines after its "run: |", less their indentation,
# up to the first line indented less.
awk '
  /^      - name: Mutation testing \(gremlins\)$/ { in_step = 1; next }
  in_step && /^        run: \|$/ { in_run = 1; next }
  in_run && /^[[:space:]]*$/ { print ""; next }
  in_run && !/^          / { exit }
  in_run { print substr($0, 11) }
' "${src_root}/.github/workflows/go.yml" >"${work}/step.sh"
if ! grep -q 'gremlins unleash' "${work}/step.sh"; then
  echo "FAIL: could not find the gremlins step's script in go.yml"
  exit 1
fi

mkdir -p "${work}/bin"
cat >"${work}/bin/gremlins" <<'EOF'
#!/usr/bin/env bash
# Stub: records GOFLAGS, then copies ${STUB_REPORT} to the --output path.
printf '%s\n' "${GOFLAGS-}" >"${STUB_DIR}/goflags"
for arg in "$@"; do
  case "${arg}" in --output=*) cp "${STUB_REPORT}" "${arg#--output=}" ;; esac
done
echo "Gathering coverage... go: no module dependencies to download"
echo "done in 25.9s"
echo "Test efficacy: whatever"
EOF
chmod +x "${work}/bin/gremlins"

failures=0

# report <file:status ...>: a gremlins report with one mutant per argument.
report() {
  local arg
  for arg in "$@"; do
    printf '%s\n' "${arg}"
  done | jq -Rn '
    [inputs | split(":") | {file: .[0], status: .[1]}]
    | {test_efficacy: 100, mutations_coverage: 100, mutants_killed: 0, mutants_lived: 0, mutants_not_covered: 0,
       files: (group_by(.file) | map({file_name: .[0].file, mutations: map({type: "CONDITIONALS_NEGATION", status, line: 1, column: 1})}))}'
}

# run_case <name> <expected substring> <unexpected substring or ""> [env args...]
# Runs the step as GitHub would (bash -eo pipefail) in a module directory, with
# the report on stdin (not a pipe, so failures count); the output is the step's log, then the recorded GOFLAGS,
# then the job summary.
run_case() {
  local name="$1" want="$2" unwanted="$3" out code
  shift 3
  rm -rf "${work}/case" && mkdir -p "${work}/case/tmp" && cd "${work}/case" || exit 1
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  cat >report.json
  out="$(PATH="${work}/bin:${PATH}" STUB_DIR="${work}/case" STUB_REPORT="${work}/case/report.json" \
    RUNNER_TEMP="${work}/case/tmp" GITHUB_STEP_SUMMARY="${work}/case/summary" \
    env -u GOFLAGS "$@" bash --noprofile --norc -eo pipefail "${work}/step.sh" 2>&1)"
  code=$?
  out+=$'\n'"GOFLAGS=$(cat goflags 2>/dev/null)"
  [[ -f summary ]] && out+=$'\n'"$(cat summary)"
  cd "${work}" || exit 1
  if [[ ${code} -ne 0 ]]; then
    echo "FAIL ${name}: exit ${code}, want 0 (the step only reports)"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  elif [[ "${out}" != *"${want}"* ]] || [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: want \"${want}\"${unwanted:+, not \"${unwanted}\"}"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# The coverage run must not come from Go's test cache.
run_case "coverage run skips the test cache" "GOFLAGS=-count=1" "" < <(report a.go:KILLED)
run_case "logs the coverage run's time" "gremlins coverage run done in 25.9s" "" < <(report a.go:KILLED)
run_case "keeps the project's GOFLAGS" "GOFLAGS=-mod=mod -count=1" "" GOFLAGS=-mod=mod < <(report a.go:KILLED)
printf 'GOFLAGS=-tags=ci\n' >"${work}/goenv"
run_case "keeps GOFLAGS set with go env -w" "GOFLAGS=-tags=ci -count=1" "" -u GOFLAGS GOENV="${work}/goenv" < <(report a.go:KILLED)

# Most runnable mutants of a package timed out: a warning, naming the package.
run_case "all timed out warns" "::warning::most mutants timed out in: internal/serve (2 of 2);" "internal/store (" \
  < <(report internal/serve/a.go:"TIMED OUT" internal/serve/b.go:"TIMED OUT" internal/serve/b.go:"NOT COVERED" internal/store/c.go:KILLED)
run_case "most timed out warns" "most mutants timed out in: internal/serve (2 of 3);" "" \
  < <(report internal/serve/a.go:"TIMED OUT" internal/serve/a.go:"TIMED OUT" internal/serve/b.go:KILLED)
run_case "timed out in the summary" "**Warning:** most mutants timed out" "" \
  < <(report internal/serve/a.go:"TIMED OUT" internal/store/c.go:KILLED)
run_case "two packages" "most mutants timed out in: . (1 of 1), internal/x (1 of 1);" "" \
  < <(report a.go:"TIMED OUT" internal/x/b.go:"TIMED OUT")

# Otherwise no such warning.
run_case "half timed out doesn't warn" "Mutation testing (gremlins)" "most mutants timed out" \
  < <(report internal/serve/a.go:"TIMED OUT" internal/serve/b.go:KILLED)
run_case "a lived mutant counts as run" "gremlins found mutants" "most mutants timed out" \
  < <(report internal/serve/a.go:"TIMED OUT" internal/serve/b.go:LIVED internal/serve/b.go:LIVED)
run_case "nothing runnable doesn't warn" "Mutation testing (gremlins)" "most mutants timed out" \
  < <(report internal/serve/a.go:"NOT COVERED" internal/serve/b.go:"NOT VIABLE")

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all mutation-step cases passed"
