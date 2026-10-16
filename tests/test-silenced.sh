#!/usr/bin/env bash
# Tests actions/silenced-checks/silenced.sh against a throwaway git repository:
# a base commit, then a change on top. Needs bash, git and awk.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/actions/silenced-checks/silenced.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git() { command git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

failures=0

# run_case <name> <expected substring> <unexpected substring or "">
# Commits a base repository, applies the commands on stdin as the change, and
# runs the script with BASE=main.
run_case() {
  local name="$1" want="$2" unwanted="$3" out code
  rm -rf "${work}/repo" && mkdir -p "${work}/repo/scripts" && cd "${work}/repo" || exit 1
  git init -q
  printf 'package p\n\nfunc F() int {\n\treturn 1\n}\n' >p.go
  printf 'package p\n\nimport "testing"\n\nfunc TestF(t *testing.T) {\n}\n' >p_test.go
  printf 'version: "2"\nlinters:\n  enable:\n    - gosec\n' >.golangci.yml
  printf '# Accepted findings.\n' >scripts/govulncheck-allow.txt
  git add -A && git commit -qm base && git switch -qc change
  bash -s
  git add -A && git commit -qm change --allow-empty
  out="$(BASE=main GITHUB_STEP_SUMMARY="${work}/summary" "${script}" 2>&1)"
  code=$?
  [[ -f "${work}/summary" ]] && out+=$'\n'"$(cat "${work}/summary")"
  rm -f "${work}/summary"
  cd "${work}" || exit 1
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

run_case "no change has no findings" "none added" "::warning" <<<":"
run_case "ordinary code has no findings" "none added" "::warning" <<<"printf 'func G() int { return 2 }\n' >>p.go"
run_case "nolint is flagged with its line" "file=p.go,line=6,title=silenced check::adds a //nolint directive" "none added" \
  <<<"printf 'func G() int { return 2 } //nolint:unparam // reason\n' >>p.go"
run_case "nosec is flagged" "adds a #nosec comment" "none added" <<<"printf 'var x = 1 // #nosec G101\n' >>p.go"
run_case "lint:ignore is flagged" "adds a //lint:ignore directive" "none added" <<<"printf '//lint:ignore U1000 reason\nvar y = 1\n' >>p.go"
run_case "t.Skip is flagged" "file=p_test.go,line=6,title=silenced check::skips a test: t.Skip(" "none added" \
  <<<"sed -i 's/^}\$/\tt.Skip(\"flaky\")\n}/' p_test.go"
run_case "t.Skip outside tests is not flagged" "none added" "skips a test" <<<"printf '// t.Skip(\"x\") in prose\n' >>p.go"
run_case "lint config change is flagged" "changes the lint config: - wrapcheck" "none added" <<<"printf '    - wrapcheck\n' >>.golangci.yml"
run_case "removed linter is flagged" "removes a line from the lint config: - gosec" "none added" <<<"sed -i '/gosec/d' .golangci.yml"
run_case "lint config comment is not flagged" "none added" "lint config" <<<"printf '# a comment\n' >>.golangci.yml"
run_case "allowlist ID is flagged" "adds GO-2026-0001 to the govulncheck allowlist" "none added" \
  <<<"printf 'GO-2026-0001 # reason, removed by #12\n' >>scripts/govulncheck-allow.txt"
run_case "allowlist comment is not flagged" "none added" "allowlist" <<<"printf '# more words\n' >>scripts/govulncheck-allow.txt"
run_case "summary table lists findings" '| `p.go:6` | adds a //nolint directive |' "" \
  <<<"printf 'func G() int { return 2 } //nolint:unparam // reason\n' >>p.go"
run_case "missing base is a warning, not none" "could not diff against main" "none added" <<<"git branch -qm main old"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all silenced-check cases passed"
