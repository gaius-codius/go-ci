#!/usr/bin/env bash
# Tests the pass/fail decisions of baseline/scripts/govulncheck.sh against a fake
# govulncheck that replays JSON fixtures. Needs bash and jq only.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The script resolves its allowlist relative to itself, so run a copy in a sandbox repo.
mkdir -p "${work}/repo/scripts" "${work}/bin"
cp "${src_root}/baseline/scripts/govulncheck.sh" "${work}/repo/scripts/govulncheck.sh"
cat >"${work}/bin/govulncheck" <<'FAKE'
#!/usr/bin/env bash
cat "${FAKE_GOVULNCHECK_OUTPUT}"
exit "${FAKE_GOVULNCHECK_EXIT:-0}"
FAKE
chmod +x "${work}/bin/govulncheck"

config='{"config":{"scan_level":"symbol","go_version":"go1.99.0"}}'
osv() { printf '{"osv":{"id":"%s","summary":"summary of %s"}}\n' "$1" "$1"; }
reachable() { printf '{"finding":{"osv":"%s","trace":[{"function":"Main","module":"m"}]}}\n' "$1"; }
imported_only() { printf '{"finding":{"osv":"%s","trace":[{"module":"m","package":"p"}]}}\n' "$1"; }

failures=0
out=""

# run_case <name> <expected exit> <expected output substring or ""> <scanner exit> <allowlist contents>
# The fixture is read from stdin.
run_case() {
  local name="$1" want_code="$2" want_text="$3" scanner_exit="$4" allow="$5"
  cat >"${work}/fixture.json"
  printf '%s' "${allow}" >"${work}/repo/scripts/govulncheck-allow.txt"
  out="$(PATH="${work}/bin:${PATH}" FAKE_GOVULNCHECK_OUTPUT="${work}/fixture.json" \
    FAKE_GOVULNCHECK_EXIT="${scanner_exit}" "${work}/repo/scripts/govulncheck.sh" 2>&1)"
  local code=$?
  # want_code 1 means "fails": any non-zero exit counts.
  if [[ ${want_code} -eq 0 && ${code} -ne 0 ]] || [[ ${want_code} -ne 0 && ${code} -eq 0 ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code} (non-zero means failure)"
    echo "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  elif [[ -n "${want_text}" && "${out}" != *"${want_text}"* ]]; then
    echo "FAIL ${name}: output lacks '${want_text}'"
    echo "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

run_case "clean scan passes" 0 "no reachable vulnerabilities" 0 "" < <({ echo "${config}"; })
run_case "import-only finding is not reachable" 0 "no reachable vulnerabilities" 0 "" < <({ echo "${config}"; osv GO-X-1; imported_only GO-X-1; })
run_case "unapproved reachable ID fails" 1 "GO-X-1: summary of GO-X-1" 0 "" < <({ echo "${config}"; osv GO-X-1; reachable GO-X-1; })
run_case "allowlisted ID passes" 0 "no reachable vulnerabilities" 0 $'GO-X-1 # reason, removed by #1\n' < <({ echo "${config}"; osv GO-X-1; reachable GO-X-1; })
run_case "one unapproved ID among allowlisted fails" 1 "GO-X-2" 0 $'GO-X-1\n' < <({ echo "${config}"; osv GO-X-1; reachable GO-X-1; osv GO-X-2; reachable GO-X-2; })
run_case "stale allowlist entry warns and passes" 0 "GO-OLD-9" 0 $'# comment\nGO-OLD-9 # gone\n' < <({ echo "${config}"; })
run_case "empty output fails" 1 "no symbol-level scan config" 0 "" < <(:)
run_case "{} output fails" 1 "no symbol-level scan config" 0 "" < <(echo '{}')
run_case "malformed output fails" 1 "not valid JSON" 0 "" < <(echo 'not json')
run_case "non-symbol scan fails" 1 "no symbol-level scan config" 0 "" < <(echo '{"config":{"scan_level":"module","go_version":"go1.99.0"}}')
run_case "scanner exiting non-zero fails" 1 "" 3 "" < <({ echo "${config}"; })
run_case "scanner non-zero with allowlisted finding fails" 1 "" 3 $'GO-X-1\n' < <({ echo "${config}"; osv GO-X-1; reachable GO-X-1; })

rm -f "${work}/repo/scripts/govulncheck-allow.txt"
out="$(PATH="${work}/bin:${PATH}" FAKE_GOVULNCHECK_OUTPUT="${work}/fixture.json" "${work}/repo/scripts/govulncheck.sh" 2>&1)"
if [[ $? -ne 1 || "${out}" != *"missing or unreadable"* ]]; then
  echo "FAIL missing allowlist should fail"
  failures=$((failures + 1))
else
  echo "ok   missing allowlist fails"
fi

# The composite action runs the script from outside the project, naming the
# module root and allowlist through GOVULNCHECK_ROOT and GOVULNCHECK_ALLOW.
mkdir -p "${work}/project/config"
printf 'GO-X-1\n' >"${work}/project/config/allow.txt"
{ echo "${config}"; osv GO-X-1; reachable GO-X-1; } >"${work}/fixture.json"
out="$(cd / && PATH="${work}/bin:${PATH}" FAKE_GOVULNCHECK_OUTPUT="${work}/fixture.json" \
  GOVULNCHECK_ROOT="${work}/project" GOVULNCHECK_ALLOW="${work}/project/config/allow.txt" \
  "${work}/repo/scripts/govulncheck.sh" 2>&1)"
if [[ $? -ne 0 || "${out}" != *"no reachable vulnerabilities"* ]]; then
  echo "FAIL root and allowlist overrides should pass with the override allowlist"
  echo "${out}" | sed 's/^/    /'
  failures=$((failures + 1))
else
  echo "ok   root and allowlist overrides"
fi
out="$(PATH="${work}/bin:${PATH}" FAKE_GOVULNCHECK_OUTPUT="${work}/fixture.json" \
  GOVULNCHECK_ROOT="${work}/project" "${work}/repo/scripts/govulncheck.sh" 2>&1)"
if [[ $? -eq 0 || "${out}" != *"missing or unreadable"* ]]; then
  echo "FAIL root override should look for scripts/govulncheck-allow.txt under the root"
  echo "${out}" | sed 's/^/    /'
  failures=$((failures + 1))
else
  echo "ok   root override resolves the default allowlist under the root"
fi

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all govulncheck gate cases passed"
