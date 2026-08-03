#!/bin/bash
# Stamp a task brief with the commit it was written against, and check it later.
#
# Why this exists. During Task 11.5 the coordinator committed a docs change into
# the same worktree while the implementer was working. No file collided and
# nothing conflicted — the implementer's base simply moved, and they had to
# notice it themselves and say so in their report. That is the failure mode this
# project has a stated rule about: a violation that ANNOUNCES ITSELF can wait for
# a ledger entry; one that PASSES quietly gets a mechanism now. A moved base
# passes. There is no red, no conflict, and no gate that reads it.
#
# It is the same family as "generate every factual claim from `git diff`", which
# fixes *I said I changed X and did not*. This one fixes *I believed my base was
# A and it was B* — the claim there is about the ground, not the work.
#
#   scripts/dispatch-base.sh stamp <brief-file>     record HEAD into the brief
#   scripts/dispatch-base.sh check <brief-file>     compare against the merge base
#
# `check` is advisory and prints; it does not fail a build, because a moved base
# is not always wrong — sometimes it is a deliberate rebase. What it must not be
# is invisible.
set -euo pipefail
cd "$(dirname "$0")/.."

MARKER="<!-- dispatch-base:"
action="${1:-}"
brief="${2:-}"

if [ -z "$action" ] || [ -z "$brief" ] || [ ! -f "$brief" ]; then
    echo "usage: scripts/dispatch-base.sh <stamp|check> <brief-file>" >&2
    exit 2
fi

case "$action" in
stamp)
    if grep -q "$MARKER" "$brief"; then
        echo "already stamped: $(grep -oE "dispatch-base: [0-9a-f]{40}" "$brief" | awk '{print $2}')" >&2
        exit 3
    fi
    head=$(git rev-parse HEAD)
    {
        echo
        echo "$MARKER $head -->"
        echo
        echo "**Base commit for this task: \`$(git rev-parse --short HEAD)\`.**"
        echo
        echo "If \`git merge-base HEAD $(git rev-parse --short HEAD)\` is not that commit when you"
        echo "finish, someone else committed into this worktree while you worked. That is not"
        echo "necessarily wrong — but your report must say which base it diffed against, because"
        echo "a moved base produces no conflict, no red, and nothing else notices."
    } >> "$brief"
    echo "stamped $brief with $head"
    ;;
check)
    stamped=$(grep -oE "dispatch-base: [0-9a-f]{40}" "$brief" | awk '{print $2}' || true)
    if [ -z "$stamped" ]; then
        echo "NOT STAMPED — $brief carries no dispatch base, so a move cannot be detected." >&2
        exit 4
    fi
    if ! git cat-file -e "$stamped^{commit}" 2>/dev/null; then
        echo "the stamped base $stamped is not in this repository — history was rewritten." >&2
        exit 5
    fi
    ancestor=$(git merge-base HEAD "$stamped")
    if [ "$ancestor" = "$stamped" ]; then
        moved=$(git rev-list --count "$stamped..HEAD")
        echo "base intact: $(git rev-parse --short "$stamped"), $moved commit(s) since."
    else
        echo "BASE MOVED: the brief was written against $(git rev-parse --short "$stamped"),"
        echo "which is no longer an ancestor of HEAD. The work was done on different ground"
        echo "than the brief describes; say so, and say which."
        exit 1
    fi
    ;;
*)
    echo "unknown action: $action" >&2
    exit 2
    ;;
esac
