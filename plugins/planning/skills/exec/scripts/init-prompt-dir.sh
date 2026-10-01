#!/bin/bash
# create a fresh, private directory for the rendered subagent prompts of one exec run
# usage: init-prompt-dir.sh <plan-name>
# e.g.: init-prompt-dir.sh fix-issues  ->  /tmp/exec-prompts-fix-issues.Ab12Cd
#
# a new directory per run, so a re-run of the same plan never picks up the previous
# run's findings files and two runs with the same plan name (two worktrees) never
# overwrite each other's prompts. mktemp creates it with mode 0700
#
# prints the directory path to stdout

set -e

name="$1"
if [ -z "$name" ]; then
    echo "error: usage: init-prompt-dir.sh <plan-name>" >&2
    exit 1
fi

case "$name" in
    */*)
        echo "error: plan name must not contain a slash: $name" >&2
        exit 1
        ;;
esac

mktemp -d "${TMPDIR:-/tmp}/exec-prompts-${name}.XXXXXX"
