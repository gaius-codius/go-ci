#!/usr/bin/env bash
# Tests actions/baseline-drift/drift.sh against a fake golangci-lint that lists
# the linters named in each config's "fake:" line. Needs bash and jq only.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# drift.sh finds the baseline relative to itself, so run a copy of the layout.
mkdir -p "${work}/go-ci/actions/baseline-drift" "${work}/go-ci/baseline/scripts" "${work}/bin"
cp "${src_root}/actions/baseline-drift/drift.sh" "${work}/go-ci/actions/baseline-drift/"
printf '# fake: errcheck govet\nignore-package-globs:\n  - github.com/gaius-codius/PROJECT/*\n' >"${work}/go-ci/baseline/.golangci.yml"
printf 'gate\n' >"${work}/go-ci/baseline/scripts/govulncheck.sh"
printf 'lint\n' >"${work}/go-ci/baseline/scripts/lint-packages.sh"
cat >"${work}/bin/golangci-lint" <<'FAKE'
#!/usr/bin/env bash
# golangci-lint <linters|formatters> --json -c <config>
[[ -n "${FAKE_LINT_FAIL:-}" ]] && { echo "cannot load config" >&2; exit 3; }
names="$(sed -n 's/^# fake: //p' "$4")"
printf '{"Enabled":['
sep=""
for n in ${names}; do printf '%s{"name":"%s"}' "${sep}" "${n}"; sep=","; done
printf ']}\n'
FAKE
chmod +x "${work}/bin/golangci-lint"

failures=0

# run_case <name> <expected output substring> <unexpected substring or "">
# Sets up the project with the commands on stdin, then runs drift.sh in it.
run_case() {
  local name="$1" want="$2" unwanted="$3" out code
  rm -rf "${work}/project" && mkdir -p "${work}/project/scripts"
  sed 's/PROJECT/example/' "${work}/go-ci/baseline/.golangci.yml" >"${work}/project/.golangci.yml"
  cp "${work}/go-ci/baseline/scripts/"* "${work}/project/scripts/"
  (cd "${work}/project" && bash -s)
  out="$(cd "${work}/project" && PATH="${work}/bin:${PATH}" "${work}/go-ci/actions/baseline-drift/drift.sh" 2>&1)"
  code=$?
  if [[ ${code} -ne 0 ]]; then
    echo "FAIL ${name}: exit ${code}, want 0"
    failures=$((failures + 1))
  elif [[ "${out}" != *"${want}"* ]] || [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

run_case "identical copies have no drift" "no drift" "::warning" <<<":"
run_case "extra linter is drift" "added: gosec" "no drift" <<<"printf '# fake: errcheck govet gosec\n' >.golangci.yml"
run_case "missing linter is drift" "removed: govet" "no drift" <<<"printf '# fake: errcheck\n' >.golangci.yml"
run_case "missing wrapcheck globs is drift" "no wrapcheck ignore-package-globs" "no drift" <<<"printf '# fake: errcheck govet\n' >.golangci.yml"
run_case "placeholder module is drift" "still contains the gaius-codius/PROJECT placeholder" "no drift" <<<"cp ../go-ci/baseline/.golangci.yml ."
run_case "set globs are not drift" "no drift" "ignore-package-globs" <<<":"
run_case "missing config is drift" ".golangci.yml is missing" "no drift" <<<"rm .golangci.yml"
run_case "edited script is drift" "scripts/govulncheck.sh differs" "no drift" <<<"echo changed >>scripts/govulncheck.sh"
run_case "missing script is drift" "scripts/lint-packages.sh is missing" "no drift" <<<"rm scripts/lint-packages.sh"
FAKE_LINT_FAIL=1 run_case "lint failure is reported, not no drift" "could not list enabled linters" "no drift" <<<":"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all drift cases passed"
