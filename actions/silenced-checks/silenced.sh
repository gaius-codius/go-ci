#!/usr/bin/env bash
# Lists the lines a change adds that switch a check off, so a person reviews
# them: //nolint, #nosec and //lint:ignore in Go files, generated-code markers
# in Go files (golangci-lint skips generated files), t.Skip in tests, any change
# to the lint config (.golangci.yml, .yaml, .toml or .json; one finding per hunk,
# or one for deleting it), and new IDs in the govulncheck allowlist. Prints a
# GitHub warning per finding and a job-summary table. It only warns: the exit
# status is always 0, and a diff that can't be made is a warning, never "none".
#
# BASE is the ref to compare with (the change is BASE...HEAD); ALLOWLIST is the
# allowlist path relative to the repository root (a leading "./" is ignored).
set -uo pipefail

if [[ -z "${BASE:-}" ]]; then
  echo "::warning title=silenced checks::BASE is empty, so the change was not checked for silenced checks"
  exit 0
fi
base="${BASE}"
allowlist="${ALLOWLIST:-scripts/govulncheck-allow.txt}"
while [[ "${allowlist}" == ./* ]]; do allowlist="${allowlist#./}"; done
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

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

# code <text>: a Markdown table cell's code span; | is escaped, and the fence
# is longer than any run of backticks in the text.
code() {
  local s=${1//|/\\|} f='`' pad=''
  [[ -z "${s}" ]] && return 0
  while [[ "${s}" == *"${f}"* ]]; do f+='`'; done
  [[ "${s}" == '`'* || "${s}" == *'`' ]] && pad=' '
  printf '%s%s%s%s%s' "${f}" "${pad}" "${s}" "${pad}" "${f}"
}

# Fixed prefixes and unquoted non-ASCII names, whatever the user's git config.
if ! diff="$(git -c core.quotePath=false -c diff.noprefix=false diff --no-color --no-ext-diff --no-renames \
  --src-prefix=a/ --dst-prefix=b/ -U0 "${base}...HEAD" -- 2>&1)"; then
  echo "::warning title=silenced checks::could not diff against ${base}, so the change was not checked for silenced checks: $(esc "${diff}")"
  exit 0
fi

# One finding per record: path, line, what it does, the line's text, separated
# by \037 and ended by \036 (a path may hold a tab or newline). LC_ALL=C keeps
# awk byte-wise, so an octal escape in a quoted path is one byte.
findings="$(LC_ALL=C awk -v allow="${allowlist}" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function out(what, text) { emit(file, line, what, text) }
  function emit(f, l, what, text) { printf "%s\037%d\037%s\037%s\036", f, (l < 1 ? 1 : l), what, trim(text) }
  function islintcfg(f) { return f ~ /(^|\/)\.golangci\.(ya?ml|toml|json)$/ }
  # unquote <"name">: undo git C-style quoting (\t, \n, \", \\, octal \ooo).
  function unquote(s,   o, i, c, j, n) {
    s = substr(s, 2, length(s) - 2); o = ""
    while ((i = index(s, "\\")) > 0) {
      o = o substr(s, 1, i - 1); c = substr(s, i + 1, 1)
      if (c ~ /[0-7]/) {
        n = 0
        for (j = 1; j <= 3 && substr(s, i + j, 1) ~ /[0-7]/; j++) n = n * 8 + substr(s, i + j, 1)
        o = o sprintf("%c", n); s = substr(s, i + j)
        continue
      }
      if (c == "t") c = "\t"; else if (c == "n") c = "\n"; else if (c == "r") c = "\r"
      else if (c == "a") c = "\007"; else if (c == "b") c = "\b"; else if (c == "f") c = "\f"
      else if (c == "v") c = "\v"
      o = o c; s = substr(s, i + 2)
    }
    return o s
  }
  # name <header path> <prefix>: the path from a ---/+++ line, without a/ or b/.
  function name(s, pre) {
    sub(/\t$/, "", s)
    if (s ~ /^".*"$/) s = unquote(s)
    if (s != "/dev/null" && index(s, pre) == 1) s = substr(s, 3)
    return s
  }
  # A changed hunk of the lint config is one finding, at its first line.
  function flush() {
    if (cfg_added + cfg_removed > 0)
      emit(file, cfg_line, "changes the lint config (+" cfg_added "/-" cfg_removed " lines)", cfg_text)
    cfg_added = cfg_removed = 0; cfg_text = ""
  }
  # The end of a file diff: a deleted lint config is one finding. An empty
  # file has no ---/+++ lines, so its path comes from "diff --git a/P b/P".
  function finish(   p, n) {
    flush()
    if (!deleted) return
    p = old
    if (p == "" && gitline !~ /^"/) {
      n = (length(gitline) - 5) / 2
      if (n >= 1 && n == int(n) && gitline == "a/" substr(gitline, 3, n) " b/" substr(gitline, 3, n)) p = substr(gitline, 3, n)
    }
    if (islintcfg(p)) emit(p, 1, "deletes the lint config", "")
    deleted = 0
  }
  END { finish() }
  # The header section runs from "diff --git" to the first @@; only there are
  # ---/+++ lines file names (an added "++ x" line also reads "+++ x").
  /^diff --git / { finish(); hdr = 1; file = old = new = ""; gitline = substr($0, 12); next }
  hdr && /^deleted file mode / { deleted = 1; next }
  hdr && /^--- / { old = name(substr($0, 5), "a/"); next }
  hdr && /^\+\+\+ / { new = name(substr($0, 5), "b/"); next }
  /^@@ / {
    flush()
    if (hdr) { file = (deleted || new == "/dev/null") ? old : new; lintcfg = !deleted && islintcfg(file); hdr = 0 }
    split($3, h, ","); line = substr(h[1], 2) + 0; cfg_line = line
    next
  }
  hdr || file == "" { next }
  {
    sign = substr($0, 1, 1); text = substr($0, 2)
    if (lintcfg && sign ~ /^[+-]$/ && trim(text) != "" && trim(text) !~ /^#/) {
      if (sign == "+") cfg_added++; else cfg_removed++
      if (cfg_text == "") cfg_text = sign " " trim(text)
    }
    if (sign != "+") next
    if (file ~ /\.go$/) {
      if (text ~ /\/\/[ \t]*nolint/) out("adds a //nolint directive", text)
      if (text ~ /#nosec/) out("adds a #nosec comment", text)
      if (text ~ /\/\/lint:(file-)?ignore/) out("adds a //lint:ignore directive", text)
      if (tolower(text) ~ /code generated|do not edit|autogenerated file/)
        out("adds a generated-code marker (golangci-lint skips generated files)", text)
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
while IFS=$'\037' read -r -d $'\036' path line what text; do
  echo "::warning file=$(escprop "${path}"),line=${line},title=silenced check::$(esc "${what}${text:+: ${text}}")"
  printf '| %s | %s | %s |\n' "$(code "${path}:${line}")" "${what//|/\\|}" "$(code "${text}")" >>"${summary}"
done < <(printf '%s' "${findings}")
exit 0
