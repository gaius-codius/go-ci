#!/usr/bin/env bash
# Tests agent/claude-go-lint-on-edit.sh with fake hook-input JSON, a throwaway Go
# module, the real go and a fake golangci-lint (FAKE_LINT_* select its behaviour).
# Needs bash, jq and go.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-go-lint-on-edit.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/failbin"

cat >"${work}/bin/golangci-lint" <<'FAKE'
#!/usr/bin/env bash
# golangci-lint fmt <file> | run --output.json.path=stdout ... <pkg>
case "$1" in
  fmt) exit 0 ;;
  run)
    [[ -n "${FAKE_LINT_CRASH:-}" ]] && { echo "panic: boom" >&2; exit 3; }
    printf '{"Issues":[%s],"Report":{}}\n' "${FAKE_LINT_ISSUES:-}"
    [[ -n "${FAKE_LINT_ISSUES:-}" ]] && exit 1
    exit 0 ;;
esac
FAKE
# A go that cannot fetch dependencies, for the tool-failure case.
cat >"${work}/failbin/go" <<'FAKE'
#!/usr/bin/env bash
echo 'go: downloading example.com/dep v1.0.0' >&2
echo 'go: example.com/dep@v1.0.0: Get "https://proxy.golang.org/": dial tcp: lookup proxy.golang.org: no such host' >&2
exit 1
FAKE
# A go that can't be found (exit 127, as `run` reports a missing tool).
mkdir -p "${work}/nogobin"
cat >"${work}/nogobin/go" <<'FAKE'
#!/usr/bin/env bash
echo 'go not found (install mise and run '"'"'mise install'"'"')' >&2
exit 127
FAKE
chmod +x "${work}/bin/golangci-lint" "${work}/failbin/go" "${work}/nogobin/go"

failures=0

# new_module: a module with package lib, its caller in package app, and a non-Go file.
new_module() {
  m="${work}/mod"
  rm -rf "${m}" && mkdir -p "${m}/lib" "${m}/app"
  printf 'module example.com/mod\n\ngo 1.22\n' >"${m}/go.mod"
  printf '# fake\n' >"${m}/.golangci.yml"
  printf 'package lib\n\n// Add adds.\nfunc Add(a, b int) int { return a + b }\n' >"${m}/lib/lib.go"
  printf 'package app\n\nimport "example.com/mod/lib"\n\n// Sum sums.\nfunc Sum() int { return lib.Add(1, 2) }\n' >"${m}/app/app.go"
  printf '# notes\n' >"${m}/NOTES.md"
}

# run_case <name> <edited file, relative to the module> <want exit> <want output substring or ""> <unwanted substring or "">
# Runs the hook on the file in the current module; set env vars before calling.
run_case() {
  local name="$1" file="$2" want_code="$3" want="$4" unwanted="$5" out code
  out="$(jq -n --arg f "${m}/${file}" '{tool_name: "Edit", tool_input: {file_path: $f}}' |
    PATH="${HOOK_PATH:-${work}/bin:${PATH}}" "${hook}" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]] || [[ -n "${want}" && "${out}" != *"${want}"* ]] ||
    [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}; output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

new_module
run_case "clean edit exits 0 quietly" lib/lib.go 0 "" "go edit hook"

run_case "non-Go file is ignored" NOTES.md 0 "" "go edit hook"
run_case "missing file is ignored" lib/nope.go 0 "" "go edit hook"

new_module
sed -i 's/func Add(a, b int)/func Add(a int)/; s/a + b/a/' "${m}/lib/lib.go"
run_case "broken caller in another package exits 2 and names it" lib/lib.go 2 "app/app.go" ""

new_module
printf 'package lib\n\nfunc Broken() int { return "x" }\n' >"${m}/lib/other.go"
run_case "type error in a file that was not edited exits 2" lib/lib.go 2 "lib/other.go" ""

new_module
FAKE_LINT_ISSUES='{"FromLinter":"revive","Text":"exported thing","Pos":{"Filename":"lib/lib.go","Line":4,"Column":1}}' \
  run_case "lint finding in the edited file exits 2" lib/lib.go 2 "lib/lib.go:4:1: exported thing (revive)" ""
FAKE_LINT_ISSUES='{"FromLinter":"revive","Text":"elsewhere","Pos":{"Filename":"lib/other.go","Line":1,"Column":1}}' \
  run_case "lint warning in an unedited file is filtered out" lib/lib.go 0 "" "elsewhere"

new_module
printf 'package lib\n\nimport "fmt"\n\nfunc Vet() { fmt.Printf("%%d\\n", "x") }\n' >"${m}/lib/vet.go"
run_case "vet finding in the edited file exits 2" lib/vet.go 2 "lib/vet.go" ""
run_case "vet warning in an unedited file is filtered out" lib/lib.go 0 "" "vet.go"

new_module
rm "${m}/.golangci.yml"
run_case "missing .golangci.yml is reported, not silent" lib/lib.go 0 '"additionalContext"' ""
run_case "missing .golangci.yml names the cause" lib/lib.go 0 "predate go-ci" ""

new_module
FAKE_LINT_CRASH=1 run_case "lint tool crash does not block" lib/lib.go 0 "golangci-lint run failed" ""
HOOK_PATH="${work}/failbin:${work}/bin:${PATH}" run_case "failed dependency fetch does not block" lib/lib.go 0 "go build could not run" ""
HOOK_PATH="${work}/nogobin:${work}/bin:${PATH}" run_case "missing go does not block" lib/lib.go 0 "go build could not run (exit 127)" ""

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
