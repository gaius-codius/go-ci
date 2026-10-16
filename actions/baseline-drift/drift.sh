#!/usr/bin/env bash
# Compares the project in the current directory with the go-ci baseline and
# prints a GitHub warning for each drift, or for a comparison that could not
# run. It only warns: the exit status is always 0.
set -uo pipefail

baseline="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../baseline" && pwd)"
drift=0

warn() {
  echo "::warning title=go-ci baseline drift::$1"
  drift=1
}

# enabled <linters|formatters> <config>: the enabled names, one per line.
enabled() {
  local json
  json="$(golangci-lint "$1" --json -c "$2")" || return 1
  jq -r '.Enabled[].name' <<<"${json}" | sort
}

if [[ ! -f .golangci.yml ]]; then
  warn ".golangci.yml is missing; copy baseline/.golangci.yml from go-ci."
else
  for kind in linters formatters; do
    if ! want="$(enabled "${kind}" "${baseline}/.golangci.yml" 2>&1)" ||
      ! have="$(enabled "${kind}" .golangci.yml 2>&1)"; then
      warn "could not list enabled ${kind} with the project's golangci-lint, so they were not compared: ${want:-}${have:-}"
      continue
    fi
    if ! d="$(diff <(printf '%s\n' "${want}") <(printf '%s\n' "${have}"))"; then
      added="$(sed -n 's/^> //p' <<<"${d}" | paste -sd, -)"
      removed="$(sed -n 's/^< //p' <<<"${d}" | paste -sd, -)"
      warn ".golangci.yml enables different ${kind} from the baseline (added: ${added:-none}; removed: ${removed:-none})."
    fi
  done
  # Settings the name comparison above can't see. Without ignore-package-globs,
  # wrapcheck flags errors returned from the project's own packages.
  if ! grep -q 'ignore-package-globs' .golangci.yml; then
    warn ".golangci.yml has no wrapcheck ignore-package-globs, so wrapcheck flags errors returned from the project's own packages; copy the wrapcheck settings and the _test.go exclusion from go-ci baseline/.golangci.yml and set them to the project's module path."
  fi
  if grep -q 'gaius-codius/PROJECT' .golangci.yml; then
    warn ".golangci.yml still contains the gaius-codius/PROJECT placeholder; set it to the project's module path (see the wrapcheck and goimports settings in go-ci baseline/.golangci.yml)."
  fi
fi

for script in govulncheck.sh lint-packages.sh; do
  if [[ ! -f "scripts/${script}" ]]; then
    warn "scripts/${script} is missing; copy baseline/scripts/${script} from go-ci (the local checks and git hooks run it)."
  elif ! cmp -s "scripts/${script}" "${baseline}/scripts/${script}"; then
    warn "scripts/${script} differs from go-ci baseline/scripts/${script}; copy it again or upstream the change."
  fi
done

if ((drift == 0)); then
  echo "go-ci baseline: no drift."
fi
exit 0
