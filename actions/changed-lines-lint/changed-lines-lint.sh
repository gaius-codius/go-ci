#!/usr/bin/env bash
# Runs golangci-lint with only the given linters on the lines changed since the
# merge base with BASE, and fails on any finding. Run it from the module root.
#   BASE     ref the change is compared with (the change is BASE...HEAD)
#   LINTERS  comma-separated linters, e.g. gocognit,nestif,wrapcheck
#
# Why the wrapcheck filter: projects keep their own .golangci.yml when they bump
# the go-ci workflow, and configs copied from older baselines lack wrapcheck's
# ignore-package-globs (the project's module) and the _test.go exclusion. The
# baseline glob "<module>/*" also misses the module's root package. Without a
# filter, wrapcheck would then flag every error returned from the project's own
# packages or from tests on changed lines. This script drops those findings
# itself, so the check behaves the same whatever the project's config says.
#
# It also refuses to lint when the merge base can't be found: golangci-lint
# would otherwise silently lint the whole tree and fail on the whole backlog.
set -uo pipefail

: "${BASE:?BASE is required}" "${LINTERS:?LINTERS is required}"

# esc <text>: escape a workflow-command message.
esc() {
  local s=${1//%/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}

# escp <text>: escape a workflow-command property value.
escp() {
  local s
  s="$(esc "$1")"
  s=${s//:/%3A}
  printf '%s' "${s//,/%2C}"
}

if ! mb="$(git merge-base "${BASE}" HEAD 2>&1)"; then
  echo "::warning title=changed lines::changed lines were not linted (no merge base with ${BASE}): $(esc "${mb}")"
  exit 0
fi

module="$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' go.mod 2>/dev/null)"
if [[ -z "${module}" ]]; then
  echo "::warning title=changed lines::could not read the module path from go.mod, so wrapcheck findings on the project's own packages are not ignored."
fi

json="$(golangci-lint run --enable-only="${LINTERS}" --new-from-merge-base="${BASE}" \
  --output.json.path=stdout --output.text.path= --show-stats=false ./...)"
code=$?
if ((code > 1)); then
  echo "::error title=changed lines::golangci-lint failed (exit ${code}), so changed lines were not linted."
  exit 1
fi

# One line per issue kept: path, line, col, linter, text (tab-separated); then
# a last line "dropped<TAB>N".
# shellcheck disable=SC2016 # jq program, not shell.
filter='
  def own($t): $mod != "" and
    ($t | (index("sig: func ") // -1) as $i | $i >= 0 and
      ($t[$i + 10:] as $s | any(
        "\($mod).", "\($mod)/", "(\($mod).", "(\($mod)/", "(*\($mod).", "(*\($mod)/";
        . as $p | $s | startswith($p))));
  (.Issues // []) as $all
  | [$all[] | select(.FromLinter == "wrapcheck" and
      ((.Pos.Filename | endswith("_test.go")) or own(.Text)))] as $drop
  | (($all - $drop)[]
      | [.Pos.Filename, (.Pos.Line | tostring), (.Pos.Column | tostring), .FromLinter,
         (.Text | gsub("[\t\n\r]"; " "))]
      | join("\t")),
    "dropped\t\($drop | length)"'
if ! parsed="$(jq -er --arg mod "${module}" "${filter}" <<<"${json}" 2>&1)"; then
  echo "::error title=changed lines::could not parse golangci-lint's JSON output (exit ${code}): $(esc "${parsed}")"
  exit 1
fi

dropped="$(tail -n1 <<<"${parsed}" | cut -f2)"
issues="$(sed '$d' <<<"${parsed}")"
if ((dropped > 0)); then
  echo "ignored ${dropped} wrapcheck findings on the project's own packages and tests"
fi
if [[ -z "${issues}" ]]; then
  if ((code != 0)); then
    echo "golangci-lint exited ${code}; its remaining findings were all ignored."
  fi
  echo "changed lines: no findings (${LINTERS})"
  exit 0
fi

n=0
while IFS=$'\t' read -r path line col linter text; do
  echo "::error file=$(escp "${path}"),line=${line},col=${col},title=$(escp "${linter}")::$(esc "${text}")"
  echo "${path}:${line}:${col}: ${text} (${linter})"
  n=$((n + 1))
done <<<"${issues}"
echo "changed lines: ${n} finding(s)"
exit 1
