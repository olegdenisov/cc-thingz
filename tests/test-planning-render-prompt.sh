#!/bin/bash
# check render-prompt.sh: override chain, wrapper stripping, substitution, failure modes

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDER="$REPO_ROOT/plugins/planning/skills/exec/scripts/render-prompt.sh"
PLUGIN_ROOT="$REPO_ROOT/plugins/planning"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

passed=0
failed=0

ok() { passed=$((passed + 1)); echo "ok: $1"; }
fail() { failed=$((failed + 1)); echo "FAIL: $1"; }
check() { if "${@:2}"; then ok "$1"; else fail "$1"; fi; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

cd "$WORK_DIR" || exit 1
out="$WORK_DIR/out"
# shellcheck disable=SC2016 # literal backticks and $ are the test input
printf '### MAJOR\n- quality: a.go:1 — keeps DEFAULT_BRANCH & a \\ and `tick` and $HOME\n' > findings.md

echo "== bundled prompts render =="
printed=$(bash "$RENDER" prompts/task.md "$out/task.md" "" PLAN_FILE_PATH=docs/plans/x.md PROGRESS_FILE_PATH=/tmp/p.txt)
check "prints the out-file path" [ "$printed" = "$out/task.md" ]
check "task: wrapper heading stripped" lacks "$out/task.md" "# Task prompt for subagent"
check "task: no fence left" lacks "$out/task.md" '```'
check "task: starts with the prompt body" [ "$(head -c 23 "$out/task.md")" = "Read the plan file at d" ]
check "task: plan path substituted" has "$out/task.md" "Read the plan file at docs/plans/x.md."
check "task: plugin root substituted" has "$out/task.md" "bash $PLUGIN_ROOT/skills/exec/scripts/stage-and-commit.sh"
check "task: no placeholder left" lacks "$out/task.md" "PLAN_FILE_PATH"
check "task: empty USER_RULES without a rules file" lacks "$out/task.md" "USER_RULES"
check "task: last line kept" has "$out/task.md" "ONE task section per run. After commit and progress log, STOP."

bash "$RENDER" prompts/stats.md "$out/stats.md" "" DEFAULT_BRANCH=main PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null
check "stats: inner fenced block survives" [ "$(grep -c '^```$' "$out/stats.md")" = "2" ]
check "stats: body ends at the last fence" has "$out/stats.md" "Keep the report compact"

bash "$RENDER" prompts/codex-review.md "$out/codex.md" "" 'DIFF_COMMAND=git diff main...HEAD' PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null
check "codex-review: body is the text after ## Prompt" lacks "$out/codex.md" "## Prompt"
check "codex-review: diff command substituted" has "$out/codex.md" "Run git diff main...HEAD to see changes."

bash "$RENDER" prompts/finalizer.md "$out/finalizer.md" "" DEFAULT_BRANCH=main PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null
check "finalizer: branch substituted" has "$out/finalizer.md" "git rebase origin/main"

echo "== file values =="
bash "$RENDER" prompts/fixer.md "$out/fixer.md" "" PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt DEFAULT_BRANCH=main FINDINGS_LIST=@findings.md > /dev/null
# shellcheck disable=SC2016 # literal text expected in the output
check "fixer: findings inserted literally" has "$out/fixer.md" '- quality: a.go:1 — keeps DEFAULT_BRANCH & a \ and `tick` and $HOME'
check "fixer: findings placeholder gone" lacks "$out/fixer.md" "FINDINGS_LIST"
: > empty.md
bash "$RENDER" prompts/fixer.md "$out/fixer-empty.md" "" PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt FINDINGS_LIST=@empty.md > /dev/null
check "fixer: an empty findings file is allowed" lacks "$out/fixer-empty.md" "FINDINGS_LIST"
err=$(bash "$RENDER" prompts/fixer.md "$out/fixer-missing.md" "" PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt FINDINGS_LIST=@missing.md 2>&1 > /dev/null); rc=$?
check "fixer: a missing findings file exits 1" [ "$rc" -eq 1 ]
check "fixer: the missing file is named" [ "$err" = "error: file for FINDINGS_LIST not found: missing.md" ]
check "fixer: nothing written for a missing findings file" [ ! -e "$out/fixer-missing.md" ]

echo "== literal values =="
# shellcheck disable=SC2016 # literal text is the test input
tricky='a&b\c\\d/e*?[x] $HOME `id` "q"'
bash "$RENDER" prompts/task.md "$out/task-tricky.md" "" "PLAN_FILE_PATH=$tricky" PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null
check "plain value is inserted literally" has "$out/task-tricky.md" "Read the plan file at $tricky."
bash "$RENDER" prompts/task.md "$out/task-named.md" "" PLAN_FILE_PATH=docs/plans/fix-USER_RULES-and-DEFAULT_BRANCH.md PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null; rc=$?
check "value containing placeholder names renders" [ "$rc" -eq 0 ]
check "placeholder names inside a value are untouched" has "$out/task-named.md" "Read the plan file at docs/plans/fix-USER_RULES-and-DEFAULT_BRANCH.md."

echo "== preambles =="
bash "$RENDER" agents/quality.txt "$out/review-quality.md" "" --preamble prompts/review-preamble.md --preamble prompts/review-critical.md \
    'DIFF_COMMAND=git diff main...HEAD' PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null
check "review: preamble first" [ "$(head -c 37 "$out/review-quality.md")" = "CRITICAL: You are a READ-ONLY reviewe" ]
# shellcheck disable=SC2016
check "review: diff command substituted" has "$out/review-quality.md" 'Run `git diff main...HEAD` to see all changes.'
check "review: critical preamble included" has "$out/review-quality.md" "Report ONLY critical and major issues"
check "review: agent file used whole" has "$out/review-quality.md" "Review code for bugs, security issues, and quality problems."
preamble_line=$(grep -n "Report ONLY critical" "$out/review-quality.md" | cut -d: -f1)
agent_line=$(grep -n "Review code for bugs" "$out/review-quality.md" | cut -d: -f1)
check "review: preambles precede the agent file" [ "$preamble_line" -lt "$agent_line" ]
bash "$RENDER" agents/smells.txt "$out/review-smells.md" "" --preamble prompts/smells-preamble.md \
    "DIFF_COMMAND=hg diff -r 'ancestor(., default)'" PLAN_FILE_PATH=p.md > /dev/null
# shellcheck disable=SC2016
check "smells: hg diff command substituted" has "$out/review-smells.md" "Run \`hg diff -r 'ancestor(., default)'\` to see all changes."
check "smells: no severity line format imposed" lacks "$out/review-smells.md" "SEVERITY: file:line"
check "smells: not told about parallel agents" lacks "$out/review-smells.md" "Other agents run in parallel"

echo "== custom rules =="
mkdir -p .claude
printf 'always use tabs & never PLAN_FILE_PATH\n' > .claude/planning-rules.md
bash "$RENDER" prompts/task.md "$out/task-rules.md" "" PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt > /dev/null
check "rules: labelled" has "$out/task-rules.md" "ADDITIONAL CUSTOM RULES:"
check "rules: content literal, placeholders inside untouched" has "$out/task-rules.md" "always use tabs & never PLAN_FILE_PATH"
printf 'EXPLICIT\n' > rules.txt
bash "$RENDER" prompts/task.md "$out/task-explicit.md" "" PLAN_FILE_PATH=p.md PROGRESS_FILE_PATH=/tmp/p.txt USER_RULES=@rules.txt > /dev/null
check "rules: explicit USER_RULES wins" has "$out/task-explicit.md" "EXPLICIT"
check "rules: explicit USER_RULES skips the rules file" lacks "$out/task-explicit.md" "always use tabs"
rm -rf .claude

echo "== override chain =="
mkdir -p .claude/exec-plan/prompts .claude/exec-plan/agents data/agents
# shellcheck disable=SC2016 # literal backticks and $ are the test input
printf 'bare override for PLAN_FILE_PATH\n```\ncode sample\n```\n' > .claude/exec-plan/prompts/task.md
bash "$RENDER" prompts/task.md "$out/task-override.md" "" PLAN_FILE_PATH=p.md > /dev/null
check "project override used" has "$out/task-override.md" "bare override for p.md"
check "override without a heading is used whole" has "$out/task-override.md" "code sample"
printf 'user level agent\n' > data/agents/quality.txt
bash "$RENDER" agents/quality.txt "$out/agent-user.md" "$WORK_DIR/data" > /dev/null
check "user override used" has "$out/agent-user.md" "user level agent"
# shellcheck disable=SC2016 # literal backticks and $ are the test input
printf '# heading\n```\nnot a wrapper in agents/\n```\n' > .claude/exec-plan/agents/quality.txt
bash "$RENDER" agents/quality.txt "$out/agent-whole.md" "" > /dev/null
check "agents/ files are never unwrapped" has "$out/agent-whole.md" "# heading"

echo "== wrapper shapes =="
# shellcheck disable=SC2016 # the fences below are literal test input
wrap() { printf '%b' "$1" > .claude/exec-plan/prompts/task.md; bash "$RENDER" prompts/task.md "$out/wrap.md" "" > /dev/null; }
# shellcheck disable=SC2016
wrap '# My prompt\nDo the work.\n```\ngit commit -m x\n```\nNEVER push.\n'
check "heading + code sample + trailing text is used whole" has "$out/wrap.md" "NEVER push."
check "heading + code sample keeps the instructions" has "$out/wrap.md" "Do the work."
# shellcheck disable=SC2016
wrap '# Wrapper\n\nUse this:\n\n```text\nbody line\n```\n'
check "language-tagged opening fence is unwrapped" [ "$(cat "$out/wrap.md")" = "body line" ]
# shellcheck disable=SC2016
wrap '# Wrapper\n\n```\nbefore\n## Prompt\nafter\n```\n'
check "a ## Prompt line inside the fence is body text" has "$out/wrap.md" "before"
# shellcheck disable=SC2016
wrap '# Wrapper\nline 2\nline 3\nline 4\n```\nsample\n```\n'
check "a fence far from the top is not a wrapper" has "$out/wrap.md" "line 4"
rm -rf .claude data

echo "== data dir =="
mkdir -p data/agents
printf 'user level agent\n' > data/agents/quality.txt
# shellcheck disable=SC2016 # the unsubstituted token is passed on purpose
CLAUDE_PLUGIN_DATA="$WORK_DIR/data" bash "$RENDER" agents/quality.txt "$out/agent-token.md" '${CLAUDE_PLUGIN_DATA}' > /dev/null
check "literal data-dir token falls back to the env var" has "$out/agent-token.md" "user level agent"
rm -rf data

echo "== prompt dir =="
INIT="$REPO_ROOT/plugins/planning/skills/exec/scripts/init-prompt-dir.sh"
dir1=$(TMPDIR="$WORK_DIR" bash "$INIT" my-plan)
dir2=$(TMPDIR="$WORK_DIR" bash "$INIT" my-plan)
check "prompt dir is created" [ -d "$dir1" ]
check "prompt dir carries the plan name" [ "${dir1#"$WORK_DIR"/exec-prompts-my-plan.}" != "$dir1" ]
check "each run gets its own prompt dir" [ "$dir1" != "$dir2" ]
bash "$INIT" > /dev/null 2>&1; rc=$?
check "prompt dir: no argument exits 1" [ "$rc" -eq 1 ]
bash "$INIT" a/b > /dev/null 2>&1; rc=$?
check "prompt dir: a slash in the name exits 1" [ "$rc" -eq 1 ]

echo "== documented commands point at bundled files =="
EXEC="$REPO_ROOT/plugins/planning/skills/exec"
documented=0
while read -r rel; do
    documented=$((documented + 1))
    check "bundled file exists: $rel" [ -f "$EXEC/references/$rel" ]
done < <(grep -ohE '(render-prompt\.sh|RENDER_SCRIPT|--preamble) (prompts|agents)/[a-z-]+\.(md|txt)' "$EXEC/SKILL.md" "$EXEC/references/prompts/review.md" | awk '{ print $2 }' | sort -u)
check "documented render commands were found" [ "$documented" -ge 10 ]
for a in quality implementation testing simplification documentation; do
    check "review playbook renders agents/$a.txt" grep -qF "RENDER_SCRIPT agents/$a.txt" "$EXEC/references/prompts/review.md"
done

echo "== failures =="
rm -f "$out/bad.md"
err=$(bash "$RENDER" prompts/fixer.md "$out/bad.md" "" PLAN_FILE_PATH=p.md 2>&1 > /dev/null); rc=$?
check "unresolved placeholder exits 1" [ "$rc" -eq 1 ]
check "unresolved placeholders are named" [ "$err" = "error: unresolved placeholders in prompts/fixer.md: PROGRESS_FILE_PATH FINDINGS_LIST" ]
check "nothing written on an unresolved placeholder" [ ! -e "$out/bad.md" ]
bash "$RENDER" prompts/nope.md "$out/bad.md" "" > /dev/null 2>&1; rc=$?
check "missing file exits non-zero" [ "$rc" -ne 0 ]
check "nothing written for a missing file" [ ! -e "$out/bad.md" ]
bash "$RENDER" agents/quality.txt "$out/bad.md" "" --preamble prompts/nope.md > /dev/null 2>&1; rc=$?
check "missing preamble exits non-zero" [ "$rc" -ne 0 ]
bash "$RENDER" prompts/task.md > /dev/null 2>&1; rc=$?
check "too few arguments exits 1" [ "$rc" -eq 1 ]
bash "$RENDER" prompts/task.md "$out/bad.md" "" stray > /dev/null 2>&1; rc=$?
check "stray argument exits 1" [ "$rc" -eq 1 ]

echo
echo "======================================"
echo "results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
