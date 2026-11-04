#!/usr/bin/env bash
# Follows a GitHub Actions run of this repository until it completes.
#
# Usage: watch-run.sh [RUN_ID] [JOB_PATTERN]
#   RUN_ID       the run to follow (default: the newest run for the commit at HEAD)
#   JOB_PATTERN  also print the result of each job whose name contains this text, even when
#                it succeeds, for example "edge ui"
#
# Prints each job that completes without succeeding (or being skipped) as it does, then the
# run's conclusion. Checks once a minute, so it can run in the background while other work goes
# on. Exits 0 when the run succeeded, 1 when it didn't, and 2 when it can't follow the run: gh
# fails at the start (such as without a valid token) or 10 times in a row, there is no run for
# HEAD yet, or the deadline passes. Needs gh, logged in or with GH_TOKEN, and jq.
#
# Environment:
#   WATCH_RUN_MINUTES  give up after this many minutes (default 90, three times a job's limit)
set -uo pipefail

usage() { sed -n '2,/^set /{/^#/p}' "$0"; }
[[ ${1:-} == @(-h|--help|help) ]] && { usage; exit 0; }
id=${1:-} pattern=${2:-}
err=$(mktemp); trap 'rm -f "$err"' EXIT
# gh's first error line, such as "HTTP 401: Bad credentials".
gh_error() { grep -m1 . "$err" || echo "no message"; }

if [[ -z $id ]]; then
  # gh run list --commit only matches the full SHA.
  if ! id=$(gh run list --commit "$(git rev-parse HEAD)" --limit 1 --json databaseId \
      --jq '.[0].databaseId // empty' 2>"$err"); then
    echo "gh run list failed: $(gh_error)" >&2; exit 2
  fi
  [[ -n $id ]] || { echo "No run for $(git rev-parse --short HEAD) yet" >&2; exit 2; }
fi
echo "Following run $id"

deadline=$(( SECONDS + ${WATCH_RUN_MINUTES:-90} * 60 ))
prev= failures=0
while true; do
  # A failed request (network, rate limit) is retried on the next round, up to 10 times in a row.
  if s=$(gh run view "$id" --json status,conclusion,jobs 2>"$err"); then
    failures=0
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
  else
    (( ++failures ))
    echo "gh run view failed ($failures of 10 in a row): $(gh_error)" >&2
    (( failures < 10 )) || { echo "Giving up on run $id" >&2; exit 2; }
  fi
  if (( SECONDS >= deadline )); then
    echo "Run $id still not completed after ${WATCH_RUN_MINUTES:-90} minutes; giving up" >&2
    exit 2
  fi
  sleep 60
done
