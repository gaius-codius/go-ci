#!/usr/bin/env bash
# Compares the project in the current directory with the go-ci baseline and
# prints a GitHub warning for each drift. Exits 0 unless a tool fails.
set -euo pipefail

baseline="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../baseline" && pwd)"
drift=0

warn() {
  echo "::warning title=go-ci baseline drift::$1"
  drift=1
}

enabled() { golangci-lint "$1" --json -c "$2" | jq -r '.Enabled[].name' | sort; }

if [[ ! -f .golangci.yml ]]; then
  warn ".golangci.yml is missing; copy baseline/.golangci.yml from go-ci."
else
  for kind in linters formatters; do
    if ! d="$(diff <(enabled "${kind}" "${baseline}/.golangci.yml") <(enabled "${kind}" .golangci.yml))"; then
      added="$(sed -n 's/^> //p' <<<"${d}" | paste -sd, -)"
      removed="$(sed -n 's/^< //p' <<<"${d}" | paste -sd, -)"
      warn ".golangci.yml enables different ${kind} from the baseline (added: ${added:-none}; removed: ${removed:-none})."
    fi
  done
fi

for script in govulncheck.sh lint-packages.sh; do
  if [[ -f "scripts/${script}" ]] && ! cmp -s "scripts/${script}" "${baseline}/scripts/${script}"; then
    warn "scripts/${script} differs from go-ci baseline/scripts/${script}; copy it again or upstream the change."
  fi
done

if ((drift == 0)); then
  echo "go-ci baseline: no drift."
fi
