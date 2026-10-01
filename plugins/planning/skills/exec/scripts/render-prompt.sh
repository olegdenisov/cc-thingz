#!/bin/bash
# render a prompt or agent file into a ready-to-use subagent prompt file
# usage: render-prompt.sh <relative-path> <out-file> <data-dir> [--preamble <relative-path>]... [KEY=VALUE | KEY=@file]...
# e.g.: render-prompt.sh prompts/task.md /tmp/exec-prompts-foo/task.md /path/to/plugin/data \
#           PLAN_FILE_PATH=docs/plans/foo.md PROGRESS_FILE_PATH=/tmp/progress-foo.txt
# e.g.: render-prompt.sh prompts/fixer.md /tmp/exec-prompts-foo/fixer.md /path/to/plugin/data \
#           PLAN_FILE_PATH=... PROGRESS_FILE_PATH=... FINDINGS_LIST=@/tmp/exec-prompts-foo/findings-phase1-iter1.md
# e.g.: render-prompt.sh agents/quality.txt /tmp/exec-prompts-foo/review-quality.md /path/to/plugin/data \
#           --preamble prompts/review-preamble.md 'DIFF_COMMAND=git diff main...HEAD' PLAN_FILE_PATH=... PROGRESS_FILE_PATH=...
#
# the orchestrator hands the subagent only the path of the rendered file, so neither the
# template nor the substituted prompt is ever generated as orchestrator output or kept in
# its context
#
# data-dir: plugin data directory, same meaning as in resolve-file.sh. an empty string, or the
# literal ${CLAUDE_PLUGIN_DATA} token left behind when Claude Code did not substitute it, falls
# back to the $CLAUDE_PLUGIN_DATA env var
#
# what it does:
#   1. resolves <relative-path> and every --preamble through the override chain (resolve-file.sh)
#   2. unwraps a prompts/ file that has the bundled wrapper shape, and uses any other file
#      whole. the wrapper shape is: first line is a "# " heading, and then either a
#      "## Prompt" line before any code fence (body = everything after it), or a code fence
#      that opens within the first few lines and closes on the last non-blank line (body =
#      the text between that opening fence and that last fence). a hand-written override that
#      merely starts with a heading and contains a code sample is therefore left alone
#   3. joins the preambles and the body, separated by blank lines
#   4. substitutes ${CLAUDE_PLUGIN_ROOT} on its own, then every KEY=VALUE literally; KEY=@file
#      substitutes the content of that file, which must exist (it may be empty). USER_RULES,
#      unless passed explicitly, is resolved here through resolve-rules.sh (planning-rules.md)
#      and labelled, or left empty. placeholders are only looked for in the template, never
#      inside a substituted value
#   5. fails if a known placeholder is still unresolved, so a half-rendered prompt never
#      reaches a subagent
#
# prints the out-file path to stdout

set -e

# bash 5.2+ expands "&" in a replacement to the matched text; values here are literal
shopt -u patsub_replacement 2>/dev/null || true

usage="usage: render-prompt.sh <relative-path> <out-file> <data-dir> [--preamble <relative-path>]... [KEY=VALUE | KEY=@file]..."
if [ $# -lt 3 ]; then
    echo "error: $usage" >&2
    exit 1
fi

path="$1"
out_file="$2"
data_dir="$3"
shift 3

if [ -z "$path" ] || [ -z "$out_file" ]; then
    echo "error: $usage" >&2
    exit 1
fi

# shellcheck disable=SC2016 # comparing against the literal unsubstituted token
if [ "$data_dir" = '${CLAUDE_PLUGIN_DATA}' ]; then
    data_dir=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# print the prompt body of a resolved file, see step 2 in the header
body_of() {
    local rel="$1" raw shape
    # errexit is not inherited by the command substitutions this runs in
    raw=$(bash "$SCRIPT_DIR/resolve-file.sh" "$rel" "$data_dir") || return 1
    case "$rel" in
        prompts/*) ;;
        *) printf '%s' "$raw"; return ;;
    esac
    # prints "<first-body-line>,<last-body-line>" for a wrapper, nothing otherwise
    shape=$(printf '%s\n' "$raw" | awk '
        NR == 1 && !/^# / { exit }
        /^## Prompt[[:space:]]*$/ && !marker && !open { marker = NR }
        /^```[A-Za-z]*[[:space:]]*$/ && !open && !marker { open = NR; lead = nonblank }
        /[^[:space:]]/ { nonblank++; last = NR; last_is_fence = ($0 ~ /^```[[:space:]]*$/) }
        END {
            if (marker) print marker + 1 "," NR
            else if (open && lead <= 3 && last_is_fence && last > open) print open + 1 "," last - 1
        }')
    if [ -n "$shape" ]; then
        printf '%s\n' "$raw" | sed -n "${shape}p"
    else
        printf '%s' "$raw"
    fi
}

preambles=()
keys=()
values=()
has_user_rules=0
while [ $# -gt 0 ]; do
    case "$1" in
        --preamble)
            if [ -z "${2:-}" ]; then
                echo "error: --preamble needs a relative path" >&2
                exit 1
            fi
            preambles+=("$2")
            shift 2
            ;;
        [A-Za-z_]*=*)
            key=${1%%=*}
            value=${1#*=}
            case "$value" in
                @*)
                    file=${value#@}
                    # a wrong path here would hand the fixer an empty findings list and
                    # make the phase look clean
                    if [ ! -f "$file" ]; then
                        echo "error: file for $key not found: $file" >&2
                        exit 1
                    fi
                    value=$(cat "$file")
                    ;;
            esac
            [ "$key" = "USER_RULES" ] && has_user_rules=1
            keys+=("$key")
            values+=("$value")
            shift
            ;;
        *)
            echo "error: unexpected argument (want --preamble <path> or KEY=VALUE): $1" >&2
            exit 1
            ;;
    esac
done

# shellcheck disable=SC2016 # the literal token is the placeholder being replaced
keys+=('${CLAUDE_PLUGIN_ROOT}')
values+=("$PLUGIN_ROOT")

if [ "$has_user_rules" -eq 0 ]; then
    rules=$(bash "$PLUGIN_ROOT/scripts/resolve-rules.sh" planning-rules.md "$data_dir")
    if [ -n "$rules" ]; then
        rules="ADDITIONAL CUSTOM RULES:"$'\n'"$rules"
    fi
    keys+=("USER_RULES")
    values+=("$rules")
fi

content=""
for rel in ${preambles[@]+"${preambles[@]}"}; do
    part=$(body_of "$rel") || exit 1
    content="${content}${part}"$'\n\n'
done
part=$(body_of "$path") || exit 1
content="${content}${part}"

# two passes, so that a value which happens to contain a placeholder name (a plan called
# fix-USER_RULES-handling.md, findings that quote DEFAULT_BRANCH) is never substituted into:
# first every placeholder in the template becomes a marker, then every marker becomes its value
mark_open=$'\001'
mark_close=$'\002'
i=0
while [ "$i" -lt "${#keys[@]}" ]; do
    content=${content//"${keys[$i]}"/${mark_open}${i}${mark_close}}
    i=$((i + 1))
done

unresolved=""
for key in PLAN_FILE_PATH PROGRESS_FILE_PATH DEFAULT_BRANCH USER_RULES FINDINGS_LIST REVIEW_PHASE DIFF_COMMAND; do
    case "$content" in
        *"$key"*) unresolved="${unresolved} ${key}" ;;
    esac
done
if [ -n "$unresolved" ]; then
    echo "error: unresolved placeholders in $path:${unresolved}" >&2
    exit 1
fi

i=0
while [ "$i" -lt "${#keys[@]}" ]; do
    content=${content//"${mark_open}${i}${mark_close}"/${values[$i]}}
    i=$((i + 1))
done

mkdir -p "$(dirname "$out_file")"
printf '%s\n' "$content" > "$out_file"
echo "$out_file"
