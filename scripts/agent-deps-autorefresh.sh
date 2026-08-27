#!/bin/zsh
# Weekly unattended agent-deps refresh, run by the local launchd agent
# com.kaisola.agent-deps-refresh (see docs/agent-deps-automation.md). Applies
# whatever scripts/agent-deps-refresh.cjs finds stale, then lands it through
# an ordinary pull request with auto-merge, so every required gate still
# fences the bump. Quiet no-op when everything is current, when the repo is
# mid-work, or when a previous refresh PR is still open.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO="${KAISOLA_REPO:-$HOME/Developer/Kaisola}"
BRANCH="chore/agent-deps-auto"
cd "$REPO"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" }

if [[ -n "$(git status --porcelain | grep -v '^?? ')" ]]; then
  log "skip: working tree has tracked changes"
  exit 0
fi
if gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' | grep -q .; then
  log "skip: a refresh PR is already open"
  exit 0
fi

git fetch -q origin
STARTED_ON="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -B "$BRANCH" origin/main

restore() { git checkout -q "$STARTED_ON" 2>/dev/null || true }

set +e
node scripts/agent-deps-refresh.cjs --check > /tmp/agent-deps-check.txt 2>&1
check_status=$?
set -e
if (( check_status == 0 )); then
  log "current: nothing to refresh"
  restore
  exit 0
elif (( check_status != 3 )); then
  log "check failed"
  cat /tmp/agent-deps-check.txt
  restore
  exit 1
fi

node scripts/agent-deps-refresh.cjs
npm run test:node > /tmp/agent-deps-tests.txt 2>&1 || {
  log "node suite failed after refresh; leaving branch unpushed for inspection"
  tail -20 /tmp/agent-deps-tests.txt
  restore
  exit 1
}

git add package.json package-lock.json native/KaisolaMac/BrokerHelper/package-policy.json
git commit -q -m "Refresh agent dependency pins

Applied by the weekly agent-deps refresh: $(grep '^stale:' /tmp/agent-deps-check.txt | sed 's/^stale: //' | paste -sd '; ' -). Node suite green locally; the landing gate and native suites fence the merge."
git push -q -u origin "$BRANCH"
gh pr create --base main --title "Refresh agent dependency pins" \
  --body "$(printf 'Weekly automated refresh.\n\n```\n%s\n```\n\nLocal node suite passed before push; required checks gate the merge.' "$(cat /tmp/agent-deps-check.txt)")"
gh pr merge "$BRANCH" --merge --auto
log "opened and armed the refresh PR"
restore
