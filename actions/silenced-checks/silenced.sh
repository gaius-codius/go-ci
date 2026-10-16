#!/usr/bin/env bash
# Lists the lines a change adds that switch a check off, so a person reviews
# them: //nolint, #nosec and //lint:ignore in Go files, t.Skip in tests, any
# change to .golangci.yml (one finding per hunk), and new IDs in the govulncheck
# allowlist. Prints a GitHub warning per finding and a job-summary table. It only warns: the exit
# status is always 0, and a diff that can't be made is a warning, never "none".
#
# BASE is the ref to compare with (the change is BASE...HEAD); ALLOWLIST is the
# allowlist path relative to the repository root.
set -uo pipefail

base="${BASE:?BASE is the ref to compare with}"
allowlist="${ALLOWLIST:-scripts/govulncheck-allow.txt}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# esc <text>: escape a workflow-command message.
esc() {
  local s=${1//%/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}

if ! diff="$(git diff --no-color --no-ext-diff --no-renames -U0 "${base}...HEAD" -- 2>&1)"; then
  echo "::warning title=silenced checks::could not diff against ${base}, so the change was not checked for silenced checks: $(esc "${diff}")"
  exit 0
fi

# One finding per line: path, line, what it does, the line's text (tab-separated).
findings="$(awk -v allow="${allowlist}" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function out(what, text) { emit(file, line, what, text) }
  function emit(f, l, what, text) { printf "%s\t%d\t%s\t%s\n", f, (l < 1 ? 1 : l), what, trim(text) }
  # A changed hunk of the lint config is one finding, at its first line.
  function flush() {
    if (cfg_added + cfg_removed > 0)
      emit(file, cfg_line, "changes the lint config (+" cfg_added "/-" cfg_removed " lines)", cfg_text)
    cfg_added = cfg_removed = 0; cfg_text = ""
  }
  END { flush() }
  /^\+\+\+ / {
    flush()
    file = substr($0, 5); sub(/\t$/, "", file)
    if (file == "/dev/null") file = ""; else sub(/^b\//, "", file)
    next
  }
  /^--- / { next }
  /^@@ / {
    flush()
    split($3, h, ","); line = substr(h[1], 2) + 0; cfg_line = line
    next
  }
  file == "" { next }
  {
    sign = substr($0, 1, 1); text = substr($0, 2)
    lintcfg = file ~ /(^|\/)\.golangci\.ya?ml$/
    if (lintcfg && trim(text) != "" && trim(text) !~ /^#/) {
      if (sign == "+") cfg_added++; else if (sign == "-") cfg_removed++
      if (cfg_text == "") cfg_text = sign " " trim(text)
    }
    if (sign == "-") next
    if (sign != "+") next
    if (file ~ /\.go$/) {
      if (text ~ /\/\/[ \t]*nolint/) out("adds a //nolint directive", text)
      if (text ~ /#nosec/) out("adds a #nosec comment", text)
      if (text ~ /\/\/lint:(file-)?ignore/) out("adds a //lint:ignore directive", text)
      if (file ~ /_test\.go$/ && text ~ /\.Skip(f|Now)?\(/) out("skips a test", text)
    } else if (file == allow) {
      id = text; sub(/#.*/, "", id); id = trim(id)
      if (id != "") out("adds " id " to the govulncheck allowlist", text)
    }
    line++
  }
' <<<"${diff}")"

if [[ -z "${findings}" ]]; then
  echo "silenced checks: none added against ${base}."
  exit 0
fi

{
  echo "### Checks switched off by this change"
  echo
  echo "Review each line: fix the code instead where you can, and keep the rest only with a reason."
  echo
  echo "| Where | What | Line |"
  echo "|---|---|---|"
} >>"${summary}"
while IFS=$'\t' read -r path line what text; do
  echo "::warning file=${path},line=${line},title=silenced check::$(esc "${what}: ${text}")"
  printf '| `%s:%s` | %s | `%s` |\n' "${path}" "${line}" "${what}" "${text//|/\\|}" >>"${summary}"
done <<<"${findings}"
exit 0
