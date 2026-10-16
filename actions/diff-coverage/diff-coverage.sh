#!/usr/bin/env bash
# Fails when too few of the Go lines a change adds or edits are covered by tests.
# A changed line counts when it holds code (it lies in a coverage block), and it
# is covered when every block on it ran. Lines in _test.go files, comments and
# declarations don't count. Uncovered lines get a GitHub warning and are listed
# in the job summary.
#
# BASE is the ref to compare with (the change is BASE...HEAD), PROFILE the
# coverage profile from `go test -coverprofile`, MIN the minimum percentage.
# Run it from the module root. A profile or diff that can't be read fails, so a
# broken setup is never mistaken for a pass.
set -uo pipefail

base="${BASE:?BASE is the ref to compare with}"
profile="${PROFILE:-coverage.out}"
min="${MIN:?MIN is the minimum percentage}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

fail() {
  echo "::error title=diff coverage::$1"
  exit 1
}

awk -v m="${min}" 'BEGIN { exit !(m ~ /^[0-9]+(\.[0-9]+)?$/ && m + 0 <= 100) }' ||
  fail "the minimum must be a percentage from 0 to 100, got '${min}'"
[[ -r "${profile}" ]] || fail "coverage profile ${profile} is missing or unreadable"
head -n 1 "${profile}" | grep -q '^mode: ' || fail "${profile} is not a Go coverage profile"
module="$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' go.mod 2>/dev/null)"
[[ -n "${module}" ]] || fail "no module path in go.mod; run this from the module root"
if ! diff="$(git diff --no-color --no-ext-diff --no-renames -U0 "${base}...HEAD" -- '*.go' ':!*_test.go' 2>&1)"; then
  fail "could not diff against ${base}: ${diff}"
fi

# Prints "total <n>", "covered <n>", then "uncovered <file> <line>" per line.
result="$(awk -v mod="${module}/" '
  FNR == NR {
    if ($0 ~ /^\+\+\+ /) { file = substr($0, 7); sub(/\t$/, "", file); next }
    if ($0 ~ /^@@ /) { split($3, h, ","); line = substr(h[1], 2) + 0; next }
    # Blank and comment-only lines inside a block are not code.
    if ($0 ~ /^\+/) { if ($0 !~ /^\+[ \t]*(\/\/.*)?$/) changed[file, line] = 1; line++ }
    next
  }
  FNR == 1 { next }
  {
    count = $NF; stmts = $(NF - 1)
    loc = substr($0, 1, length($0) - length($NF) - length($(NF - 1)) - 2)
    if (stmts == 0 || index(loc, mod) != 1) next
    if (!(loc in maxc) || count + 0 > maxc[loc]) maxc[loc] = count + 0
  }
  END {
    for (loc in maxc) {
      f = loc; sub(/:[^:]*$/, "", f); f = substr(f, length(mod) + 1)
      r = loc; sub(/.*:/, "", r); split(r, ends, ","); split(ends[1], s, "."); split(ends[2], e, ".")
      for (l = s[1] + 0; l <= e[1] + 0; l++) {
        if (!((f, l) in changed)) continue
        touched[f, l] = 1
        if (maxc[loc] == 0) bad[f, l] = 1
      }
    }
    for (k in touched) { total++; if (!(k in bad)) covered++ }
    printf "total %d\ncovered %d\n", total, covered
    for (k in bad) { split(k, p, SUBSEP); printf "uncovered %s %d\n", p[1], p[2] }
  }
' <(printf '%s\n' "${diff}") "${profile}")" || fail "could not compare ${profile} with the diff"

total="$(awk '$1 == "total" { print $2 }' <<<"${result}")"
covered="$(awk '$1 == "covered" { print $2 }' <<<"${result}")"
if ((total == 0)); then
  echo "diff coverage: no changed code lines against ${base}."
  exit 0
fi
pct="$(awk -v c="${covered}" -v t="${total}" 'BEGIN { printf "%.1f", 100 * c / t }')"

# Uncovered lines as ranges of consecutive lines, per file.
ranges="$(awk '$1 == "uncovered" { print $2, $3 }' <<<"${result}" | sort -k1,1 -k2,2n | awk '
  $1 == f && $2 == last + 1 { last = $2; next }
  { if (f != "") print f, first, last; f = $1; first = last = $2 }
  END { if (f != "") print f, first, last }
')"

{
  echo "### Diff coverage"
  echo
  echo "${covered} of ${total} changed code lines are covered by tests (${pct}%; minimum ${min}%)."
  if [[ -n "${ranges}" ]]; then
    echo
    echo "Not covered:"
    echo
    while read -r f a b; do
      if ((a == b)); then echo "- \`${f}:${a}\`"; else echo "- \`${f}:${a}-${b}\`"; fi
    done <<<"${ranges}"
  fi
} >>"${summary}"

if [[ -n "${ranges}" ]]; then
  while read -r f a b; do
    echo "::warning file=${f},line=${a},endLine=${b},title=diff coverage::changed lines not covered by tests"
  done <<<"${ranges}"
fi

echo "diff coverage: ${covered} of ${total} changed code lines covered (${pct}%, minimum ${min}%)."
# Compare the exact ratio; pct is rounded for display only.
if awk -v c="${covered}" -v t="${total}" -v m="${min}" 'BEGIN { exit !(100 * c < m * t) }'; then
  fail "changed code lines are ${pct}% covered, below the minimum of ${min}% (see the job summary)"
fi
exit 0
