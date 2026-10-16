#!/usr/bin/env bash
# Fails when too few of the Go lines a change adds or edits are covered by tests.
# A changed line counts when it holds code (it lies in a coverage block), and it
# is covered when every block on it ran. Lines in _test.go files, blank lines,
# comments and declarations don't count. Uncovered lines get a GitHub warning
# and are listed in the job summary.
#
# A changed line is a comment when it is blank after a "//", or when, in the
# added text of one hunk, it starts with "/*" or "*/", lies between them, or
# starts with "*" and a space (a comment's continuation). A comment that opens
# after code on the same line, or "/*" inside a string, is not tracked, so the
# lines after it count as code unless they start that way.
#
# BASE is the ref to compare with (the change is BASE...HEAD), PROFILE the
# coverage profile from `go test -coverprofile`, MIN the minimum percentage.
# Run it from the module root, which must be the repository root: go.mod is read
# there and the diff's paths are relative to the repository root. A profile or
# diff that can't be read, or a profile with nothing for this module, fails, so
# a broken setup is never mistaken for a pass.
set -uo pipefail

# esc <text>: escape a workflow-command message.
esc() {
  local s=${1//%/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}

# escprop <text>: escape a workflow-command property value (also : and ,).
escprop() {
  local s
  s="$(esc "$1")"
  s=${s//:/%3A}
  printf '%s' "${s//,/%2C}"
}

fail() {
  echo "::error title=diff coverage::$(esc "$1")"
  exit 1
}

base="${BASE:-}"
profile="${PROFILE:-coverage.out}"
min="${MIN:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

[[ -n "${base}" ]] || fail "BASE is empty; set it to the ref to compare with"
[[ -n "${min}" ]] || fail "MIN is empty; set it to the minimum percentage, 0 to 100"
# At most six decimals keep the exact comparison below within awk's integers.
awk -v m="${min}" 'BEGIN { exit !(m ~ /^[0-9]+(\.[0-9]+)?$/ && length(m) - index(m ".", ".") <= 6 && m + 0 <= 100) }' ||
  fail "the minimum must be a percentage from 0 to 100 with at most six decimals, got '${min}'"
if ! top="$(git rev-parse --show-toplevel 2>&1)"; then
  fail "not in a git repository: ${top}"
fi
[[ "$(cd -- "${top}" && pwd -P)" == "$(pwd -P)" ]] ||
  fail "run this from the repository root (${top}), where the module's go.mod must be; ran in $(pwd)"
[[ -r "${profile}" ]] || fail "coverage profile ${profile} is missing or unreadable"
module="$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' go.mod 2>/dev/null)"
[[ -n "${module}" ]] || fail "no module path in go.mod; the module must be at the repository root"
# Fixed prefixes and unquoted paths whatever the user's git config says.
if ! diff="$(git -c core.quotePath=false -c diff.noprefix=false diff --no-color --no-ext-diff \
  --no-renames --src-prefix=a/ --dst-prefix=b/ -U0 "${base}...HEAD" -- '*.go' ':!*_test.go' 2>&1)"; then
  fail "could not diff against ${base}: ${diff}"
fi

# Prints "total<TAB>n", "covered<TAB>n", then "uncovered<TAB>line<TAB>file" per
# line, the file last so a tab in its name survives. On a bad diff or profile it
# prints the reason and exits 3. LC_ALL=C makes awks agree on bytes.
result="$(LC_ALL=C awk -v mod="${module}/" '
  function oops(msg) { if (err == "") err = msg }
  # unq: a C-quoted git path without its quotes, or "" when it cannot be read.
  function unq(s,   out, i, c, o) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\"") return ""
      if (c != "\\") { out = out c; continue }
      c = substr(s, ++i, 1)
      if (c == "t") out = out "\t"
      else if (c == "\"" || c == "\\") out = out c
      else if (substr(s, i, 3) ~ /^[0-3][0-7][0-7]$/) {
        o = (substr(s, i, 1) * 64) + (substr(s, i + 1, 1) * 8) + substr(s, i + 2, 1)
        if (o == 10 || o == 13 || o == 0) return ""
        out = out sprintf("%c", o); i += 2
      } else return ""
    }
    return out
  }
  # code: whether an added line holds more than blanks and comments.
  function code(c,   p) {
    if (incomm) {
      if (!(p = index(c, "*/"))) return 0
      incomm = 0
      return code(substr(c, p + 2))
    }
    sub(/^[ \t]+/, "", c)
    if (c == "" || substr(c, 1, 2) == "//") return 0
    if (substr(c, 1, 2) == "/*") { incomm = 1; return code(substr(c, 3)) }
    if (substr(c, 1, 2) == "*/") return code(substr(c, 3))
    return c !~ /^\*([ \t]|$)/
  }
  FILENAME == ARGV[1] {
    if ($0 ~ /^diff --git /) { hdr = 1; file = ""; incomm = 0; next }
    if (hdr && $0 ~ /^\+\+\+ /) {
      f = substr($0, 5); sub(/\t$/, "", f)
      if (f ~ /^"/) f = (f ~ /^".*"$/) ? unq(substr(f, 2, length(f) - 2)) : ""
      if (f == "/dev/null") file = ""
      else if (f ~ /^b\//) file = substr(f, 3)
      else oops("could not read the file name in the diff header: " $0)
      next
    }
    if ($0 ~ /^@@ /) { hdr = 0; incomm = 0; split($3, h, ","); line = substr(h[1], 2) + 0; next }
    if (hdr || $0 !~ /^\+/) next
    if (file == "") { oops("an added line has no file in the diff: " $0); next }
    if (code(substr($0, 2))) changed[file, line] = 1
    line++
    next
  }
  FNR == 1 {
    if ($0 !~ /^mode: (set|count|atomic)$/) oops(FILENAME " is not a Go coverage profile: the first line must be mode: set, count or atomic")
    next
  }
  $0 == "" { next }
  !match($0, /:[0-9]+\.[0-9]+,[0-9]+\.[0-9]+ [0-9]+ [0-9]+$/) || RSTART == 1 {
    oops(FILENAME " line " FNR " is not a coverage record: " $0); next
  }
  {
    loc = substr($0, 1, length($0) - length($NF) - length($(NF - 1)) - 2)
    if (index(loc, mod) != 1) next
    ours++
    if ($(NF - 1) == 0) next
    if (!(loc in maxc) || $NF + 0 > maxc[loc]) maxc[loc] = $NF + 0
  }
  END {
    if (err == "" && !ours) oops(FILENAME " has no coverage records for module " substr(mod, 1, length(mod) - 1))
    if (err != "") { print err; exit 3 }
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
    printf "total\t%d\ncovered\t%d\n", total, covered
    for (k in bad) { split(k, p, SUBSEP); printf "uncovered\t%d\t%s\n", p[2], p[1] }
  }
' <(printf '%s\n' "${diff}") "${profile}")"
case $? in
  0) ;;
  3) fail "${result}" ;;
  *) fail "could not compare ${profile} with the diff" ;;
esac

total="$(awk -F '\t' '$1 == "total" { print $2 }' <<<"${result}")"
covered="$(awk -F '\t' '$1 == "covered" { print $2 }' <<<"${result}")"
if ((total == 0)); then
  echo "diff coverage: no changed code lines against ${base}."
  exit 0
fi
# Rounded down, so a share below 100% never reads as 100.0%.
pct="$(awk -v c="${covered}" -v t="${total}" 'BEGIN { printf "%.1f", int(1000 * c / t) / 10 }')"

# Uncovered lines as "first<TAB>last<TAB>file" ranges of consecutive lines.
ranges="$(awk -F '\t' '$1 == "uncovered" { print substr($0, length($1) + 2) }' <<<"${result}" |
  LC_ALL=C sort -t "$(printf '\t')" -k2 -k1,1n | awk -F '\t' '
    { l = $1 + 0; f = substr($0, length($1) + 2) }
    f == file && l == last + 1 { last = l; next }
    { if (file != "") printf "%d\t%d\t%s\n", first, last, file; file = f; first = last = l }
    END { if (file != "") printf "%d\t%d\t%s\n", first, last, file }
  ')"

{
  echo "### Diff coverage"
  echo
  echo "${covered} of ${total} changed code lines are covered by tests (${pct}%; minimum ${min}%)."
  if [[ -n "${ranges}" ]]; then
    echo
    echo "Not covered:"
    echo
    while IFS=$'\t' read -r a b f; do
      if ((a == b)); then echo "- \`${f}:${a}\`"; else echo "- \`${f}:${a}-${b}\`"; fi
    done <<<"${ranges}"
  fi
} >>"${summary}"

if [[ -n "${ranges}" ]]; then
  while IFS=$'\t' read -r a b f; do
    echo "::warning file=$(escprop "${f}"),line=${a},endLine=${b},title=diff coverage::changed lines not covered by tests"
  done <<<"${ranges}"
fi

echo "diff coverage: ${covered} of ${total} changed code lines covered (${pct}%, minimum ${min}%)."
# Compare exactly: MIN as an integer over 10^decimals, against the line counts.
if awk -v c="${covered}" -v t="${total}" -v m="${min}" 'BEGIN {
  n = split(m, p, "."); d = (n > 1) ? length(p[2]) : 0; s = 1
  for (i = 0; i < d; i++) s *= 10
  exit !(100 * c * s < (p[1] * s + (n > 1 ? p[2] : 0)) * t)
}'; then
  fail "changed code lines are ${pct}% covered (${covered} of ${total}), below the minimum of ${min}% (see the job summary)"
fi
exit 0
