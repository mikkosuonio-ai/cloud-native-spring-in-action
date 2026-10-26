#!/usr/bin/env bash
# Follows a GitHub Actions run of this repository until it completes.
#
# Usage: watch-run.sh [RUN_ID] [JOB_PATTERN]
#   RUN_ID       the run to follow (default: the newest run for the commit at HEAD)
#   JOB_PATTERN  also print the result of each job whose name contains this text, even when
#                it succeeds, for example "edge ui"
#
# Prints each job that completes without succeeding (or being skipped) as it does, then the
# run's conclusion. Exits 0 when the run succeeded and 1 otherwise. Checks once a minute, so
# it can run in the background while other work goes on. Needs gh, logged in or with GH_TOKEN,
# and jq.
set -uo pipefail

usage() { sed -n '2,/^set /{/^#/p}' "$0"; }
[[ ${1:-} == @(-h|--help|help) ]] && { usage; exit 0; }
id=${1:-} pattern=${2:-}
if [[ -z $id ]]; then
  # gh run list --commit only matches the full SHA.
  id=$(gh run list --commit "$(git rev-parse HEAD)" --limit 1 --json databaseId --jq '.[0].databaseId')
  [[ -n $id ]] || { echo "No run for $(git rev-parse --short HEAD) yet" >&2; exit 2; }
fi
echo "Following run $id"

prev=
while true; do
  # A failed request (network, rate limit) is retried on the next round.
  if s=$(gh run view "$id" --json status,conclusion,jobs 2>/dev/null); then
    done_jobs=$(jq -r '.jobs[] | select(.status == "completed") | "\(.name): \(.conclusion)"' <<<"$s" | sort)
    new=$(comm -13 <(echo "$prev") <(echo "$done_jobs"))
    grep -v -e ': success$' -e ': skipped$' <<<"$new" | grep .
    [[ -n $pattern ]] && grep -F -e "$pattern" <<<"$new" | grep -e ': success$' -e ': skipped$'
    prev=$done_jobs
    if [[ $(jq -r .status <<<"$s") == completed ]]; then
      conclusion=$(jq -r .conclusion <<<"$s")
      echo "Run $id completed: $conclusion"
      [[ $conclusion == success ]]; exit
    fi
  fi
  sleep 60
done
