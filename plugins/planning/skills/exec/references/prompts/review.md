# Review fanout playbook

This file is a playbook for the main orchestrator session — NOT a prompt to spawn into a subagent. Subagents do not have access to the Agent tool in current Claude Code, so the parallel fanout below must be initiated from the main session.

Resolve placeholders (`REVIEW_PHASE`, `RENDER_SCRIPT`, `PLUGIN_DATA_DIR`, `PROMPT_DIR`, `FINDINGS_FILE`) and fill the `<diff-command>`, `<plan-file-path>` and `<progress-file>` values in the render commands (`<diff-command>` is `git diff <default-branch>...HEAD` for git and `hg diff -r 'ancestor(., <default-branch>)'` for hg — it holds single quotes on hg, which is why that argument is double-quoted) — the `KEY=` part of each argument stays literal, it names the placeholder the script replaces. Then follow the instructions below from the main session: render the agent prompts to files, launch the specified parallel Agent calls, collect findings from all returned agents, and pass them to the fixer subagent. The orchestrator does NOT fix issues itself — the fixer is a separate subagent that handles fixes.

## How to fan out (READ THIS CAREFULLY)

In your NEXT assistant response, emit N Agent tool_use blocks TOGETHER — all N must appear in the same response, no text between them, no pausing to read results. Multiple tool_use blocks in one response run in PARALLEL; tool_use blocks spread across separate responses run SEQUENTIALLY (Nx runtime). The agents are fully independent — no shared state, no ordering. Do NOT use run_in_background. After emitting all N tool calls, stop generating — the orchestrator response ends there, agents run in parallel, and your next response begins after all N return.

Agent prompts are rendered to files by `RENDER_SCRIPT`, which resolves the agent file through the override chain, prepends the review preamble (READ-ONLY rule, how to get the diff, plan and progress file, severity tagging) and substitutes the placeholders. Do NOT read the agent files or the preamble yourself and do NOT write their text into an Agent call — the `prompt` of each Agent call is only this launch line, with the rendered path filled in:

"Read the file <rendered-path> in full and follow it exactly — it is your complete prompt. Do not start any work before reading it."

Do NOT embed diffs in agent prompts — the rendered prompt tells each agent to run git commands itself.

## Comprehensive mode (5 agents)

Used when `REVIEW_PHASE` is `comprehensive`.

Render the 5 agent prompts in ONE Bash call (this is not parallel work — run it first, then launch the agents):

```
bash RENDER_SCRIPT agents/quality.txt PROMPT_DIR/review-quality.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>' && \
bash RENDER_SCRIPT agents/implementation.txt PROMPT_DIR/review-implementation.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>' && \
bash RENDER_SCRIPT agents/testing.txt PROMPT_DIR/review-testing.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>' && \
bash RENDER_SCRIPT agents/simplification.txt PROMPT_DIR/review-simplification.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>' && \
bash RENDER_SCRIPT agents/documentation.txt PROMPT_DIR/review-documentation.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>'
```

In your next assistant response, emit 5 Agent tool_use blocks together. Each with `mode: "bypassPermissions"`, `subagent_type: "general-purpose"`, and the launch line pointing at one of the 5 rendered files (`PROMPT_DIR/review-quality.md`, `review-implementation.md`, `review-testing.md`, `review-simplification.md`, `review-documentation.md`).

After ALL 5 agents return: if none of them reported an issue, do not write `FINDINGS_FILE` — the phase is clean. Otherwise write a STRICT bullet-list report to `FINDINGS_FILE` with the Write tool — no prose summary, no narrative, no "agents converge on" sentences. Format requirements:

- Group findings by severity in this order: CRITICAL, MAJOR, MINOR. Use a heading per severity (`### CRITICAL`, `### MAJOR`, `### MINOR`). Skip a severity heading if it has zero findings.
- Under each heading, one bullet per finding using EXACTLY this shape: `- <agent-name>: <file:line> — <description>`
- Preserve the original agent attribution (e.g. `quality`, `implementation`, `testing`, `simplification`, `documentation` — whichever agent files were resolved). Do NOT rewrite as "agents" or "multiple agents".
- If two agents reported the same file:line + same issue, merge into one bullet and prefix both agent names separated by `+` (e.g. `- quality+implementation: main.go:12 — ...`).
- Do NOT verify, fix, or dismiss findings here — the fixer agent does that. Just emit the report verbatim from agent outputs.
- Omit agents that found nothing entirely (no need to mention them).
- After the bullet list, on its own line, emit one summary line: `Total: <N> findings (<C> critical, <M> major, <m> minor)`.

Do NOT add explanatory prose, recommendations, or commentary. The file goes straight to the fixer and to the progress file — write the full report ONCE, into the file; do not repeat it in a Bash command or in the fixer's Agent call. To the user, show a short list — one line per finding, `file:line` and a few words each, not the full description — followed by the path of the file, then the `Total:` line.

## Critical-only mode (2 agents)

Used when `REVIEW_PHASE` is `critical`.

Render only `quality` and `implementation`, adding the critical-only preamble after the common one:

```
bash RENDER_SCRIPT agents/quality.txt PROMPT_DIR/review-quality.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md --preamble prompts/review-critical.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>' && \
bash RENDER_SCRIPT agents/implementation.txt PROMPT_DIR/review-implementation.md 'PLUGIN_DATA_DIR' --preamble prompts/review-preamble.md --preamble prompts/review-critical.md "DIFF_COMMAND=<diff-command>" 'PLAN_FILE_PATH=<plan-file-path>' 'PROGRESS_FILE_PATH=<progress-file>'
```

In your next assistant response, emit 2 Agent tool_use blocks together. Same `mode`, `subagent_type` and launch line as comprehensive mode.

After BOTH agents return, write the same STRICT bullet-list report to `FINDINGS_FILE` as in comprehensive mode (groupings by severity, exact bullet shape, agent attribution preserved, no prose summary). Additional rule for this mode:

- Drop any MINOR findings if agents returned them anyway. Only CRITICAL and MAJOR headings appear here.
- If neither agent reported CRITICAL or MAJOR findings, do not write `FINDINGS_FILE`; emit exactly: `Critical re-check: clean — no critical/major findings.` and stop.
