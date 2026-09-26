#!/bin/bash
# check the per-task model contract between /planning:make and /planning:exec

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(sys.argv.pop())
PLANNING = ROOT / "plugins/planning"
MAKE = (PLANNING / "commands/make.md").read_text()
SKILL = (PLANNING / "skills/exec/SKILL.md").read_text()
MODEL_LINE = re.compile(r"^\*\*Model:\*\* (\S+)", re.MULTILINE)


class TaskModelTests(unittest.TestCase):
    def test_every_template_task_has_model_line(self):
        sections = re.split(r"^### (?:Task|Iteration) [^\n]*\n", MAKE, flags=re.MULTILINE)[1:]
        self.assertGreaterEqual(len(sections), 5)
        for section in sections:
            first = section.split("\n", 1)[0]
            self.assertRegex(first, MODEL_LINE)

    def test_make_documents_rubric(self):
        rubric = MAKE.split("### task model selection", 1)[1].split("\n## ", 1)[0]
        for expected in ("default: `sonnet`", "`opus` if ANY", "`haiku` only if ALL", "pick the higher model"):
            self.assertIn(expected, rubric)

    def test_exec_passes_model_to_task_agent(self):
        loop = SKILL.split("### Step 6.", 1)[1].split("\n### Step ", 1)[0]
        for expected in (
            "**Model:** <model>",
            "`haiku`, `sonnet`, `opus`, `fable`",
            '`model: "<model>"` — only when step 4 resolved one',
            "`haiku` → `sonnet` → `opus`",
            "[deviation] task N: retried on",
        ):
            self.assertIn(expected, loop)
        self.assertLess(loop.index("Resolve the task model"), loop.index("Spawn a subagent"))


unittest.main(argv=["test"], verbosity=1)
PY
