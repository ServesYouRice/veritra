#!/bin/bash
# Gate: blocks `git push` and pull-request creation in Claude web sessions
# until .claude/hooks/check.sh has passed on exactly the code being pushed.
# Shared template from ServesYouRice/handbook (templates/claude-cloud). Do not edit per repo.
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
if [ "$tool" = "Bash" ]; then
  cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
  # Only `git ... push`; ignore everything else.
  grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([[:space:]]|$)' <<<"$cmd" || exit 0
  # Deleting a remote branch pushes no code.
  grep -Eq '[[:space:]](--delete|-d)([[:space:]]|$)|[[:space:]]:[^[:space:]]+' <<<"$cmd" && exit 0
fi

dir=$(jq -r '.cwd // ""' <<<"$input")
cd "${dir:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

head_tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null) || exit 0
marker="$(git rev-parse --git-dir)/claude-checks-passed"
[ -f "$marker" ] && [ "$(cat "$marker")" = "$head_tree" ] && exit 0

# Changes that touch only docs need no checks.
base=""
for ref in origin/HEAD origin/main origin/master; do
  base=$(git merge-base HEAD "$ref" 2>/dev/null) && break
done
if [ -n "$base" ]; then
  changed=$(git diff --name-only "$base" HEAD)
  if [ -z "$changed" ] || ! grep -Evq '(\.(md|txt)$|^docs/)' <<<"$changed"; then
    exit 0
  fi
fi

cat >&2 <<'MSG'
Blocked: the full checks have not passed on this exact code.
Run `.claude/hooks/check.sh` (use run_in_background if it is slow), fix any
failures, commit, then push or open the pull request again.
If the checks cannot run here (missing tool or service), say so to the user
instead of working around this gate.
MSG
exit 2
