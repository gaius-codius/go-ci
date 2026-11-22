#!/usr/bin/env bash
# Tests baseline/scripts/lint-packages.sh against a fake golangci-lint that logs
# its arguments, with a BSD-style realpath on PATH that rejects --relative-to,
# as macOS's does. Needs bash and git only.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/baseline/scripts/lint-packages.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/bin" "${work}/repo/pkg/sub"
cat >"${work}/bin/golangci-lint" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_LOG}"
FAKE
cat >"${work}/bin/realpath" <<'FAKE'
#!/usr/bin/env bash
# macOS's /usr/bin/realpath accepts only -q.
for a in "$@"; do
  [[ ${a} == -* && ${a} != -q ]] && { echo "usage: realpath [-q] [path ...]" >&2; exit 1; }
done
exit 0
FAKE
chmod +x "${work}/bin/golangci-lint" "${work}/bin/realpath"

(
  cd "${work}/repo" && git init -q -b main &&
    touch main.go pkg/a.go pkg/b.go pkg/sub/c.go pkg/notes.txt
) || {
  echo "could not set up the git repository"
  exit 1
}
repo="$(cd "${work}/repo" && pwd -P)"

failures=0

# run_case <name> <expected golangci-lint calls, one per line, or ""> <script args...>
# Runs from the repository's pkg/ directory, as a hook started elsewhere would.
run_case() {
  local name="$1" want="$2"
  shift 2
  : >"${work}/log"
  local out code
  out="$(cd "${repo}/pkg" && PATH="${work}/bin:${PATH}" FAKE_LOG="${work}/log" "${script}" "$@" 2>&1)"
  code=$?
  local got
  got="$(cat "${work}/log")"
  if [[ ${code} -ne 0 ]]; then
    echo "FAIL ${name}: exit ${code}"
    echo "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  elif [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: golangci-lint was called with"
    echo "${got}" | sed 's/^/    got:  /'
    echo "${want}" | sed 's/^/    want: /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

run_case "repo-relative paths" $'fmt pkg/a.go pkg/sub/c.go\nrun ./pkg ./pkg/sub' pkg/a.go pkg/sub/c.go
run_case "leading ./ is dropped" $'fmt pkg/a.go main.go\nrun ./. ./pkg' ./pkg/a.go ././main.go
run_case "absolute paths inside the repo" $'fmt pkg/b.go\nrun ./pkg' "${repo}/pkg/b.go"
run_case "one package for two files" $'fmt pkg/a.go pkg/b.go\nrun ./pkg' pkg/a.go pkg/b.go
run_case "non-Go and missing files are skipped" $'fmt pkg/a.go\nrun ./pkg' pkg/notes.txt pkg/gone.go pkg/a.go
run_case "nothing to lint" "" pkg/notes.txt pkg/gone.go
run_case "no arguments" ""

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all lint-packages cases passed"
