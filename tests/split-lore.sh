#!/usr/bin/env bash
set -uo pipefail                      # deliberately not -e: cases run failures
# Stub-free harness for scripts/split-lore.sh. Every case builds a throwaway repo in
# $work, runs the real script against it, and asserts on the resulting git state. No
# network, no remote: the cases answer "1" (local-only) at the prompt, so the push
# branch is never taken.
#
# The regression this exists for: the script used to `cp -r lore lore.split-backup`
# INSIDE the worktree and then `git add -A`. With this repository's own .gitignore
# (no catch-all) that committed the backup, so "remove inline lore" was recorded as a
# RENAME -- the KB stayed tracked -- and the following `mv` left the worktree dirty
# with deleted tracked files and an untracked nested repo.

src=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$src/scripts/split-lore.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
ok()  { printf '  ok   %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2-}"; failed=$((failed + 1)); }
same()   { if [[ $2 == "$3" ]];   then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()    { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "output lacks [$3]: $2"; fi; }
lacks()  { if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "output should not contain [$3]: $2"; fi; }
is_dir() { if [[ -d $2 ]]; then ok "$1"; else bad "$1" "$2 is not a directory"; fi; }
absent() { if [[ ! -e $2 ]]; then ok "$1"; else bad "$1" "$2 exists"; fi; }
clean()  { local st; st=$(git -C "$2" status --porcelain); if [[ -z $st ]]; then ok "$1"; else bad "$1" "worktree not clean:"$'\n'"$st"; fi; }

# setup <case-name> [gitignore-body]: a throwaway workspace with an inline lore/.
# Default .gitignore is THIS repository's shape -- four lines of editor cruft and no
# catch-all -- because that is the shape the script was getting wrong.
setup() {
    local box="$work/$1"
    mkdir -p "$box/scripts" "$box/lore/knowledge/adrs" "$box/lore/_tools"
    cp "$script" "$box/scripts/split-lore.sh"
    if [[ -n ${2-} ]]; then printf '%s\n' "$2" > "$box/.gitignore"
    else printf '# Editor / OS cruft\n*.bak\n*~\n.DS_Store\n' > "$box/.gitignore"; fi
    printf '{"knowledge_base":"lore","repos":[{"name":"lore"}]}\n' > "$box/household.json"
    echo "# Workspace" > "$box/README.md"
    echo "adr" > "$box/lore/knowledge/adrs/0001-x.md"
    echo "tool" > "$box/lore/_tools/cli.js"
    git -C "$box" init -q -b main .
    git -C "$box" config user.email t@t
    git -C "$box" config user.name T
    git -C "$box" add -A
    git -C "$box" commit -qm init
    echo "$box"
}

# run <box> <stdin>: the script, with its prompts answered. Sets $out and $status.
# The identity is exported rather than configured in the box: the script `git init`s a
# SECOND repo (the sibling) and commits into it, and a fresh repo has no local identity. On
# a CI runner there is no global one either, so without these four the sibling commit dies
# with "empty ident name" and five cases fail for a reason that has nothing to do with the
# script.
run() {
    out=$(cd "$1" && printf '%s' "$2" | GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t \
        GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t bash scripts/split-lore.sh 2>&1)
    status=$?
}

# --- the ordinary split, on a repo with no catch-all .gitignore ------------------
box=$(setup plain)
run "$box" $'1\ny\n'
same "plain: exits 0"                      "$status" "0"
has  "plain: says it is done"              "$out" "Done. lore/ is now a sibling git repo."
clean "plain: parent worktree is clean"    "$box"
is_dir "plain: lore/ is restored"          "$box/lore"
is_dir "plain: lore/ is its own repo"      "$box/lore/.git"
same "plain: the sibling has one commit"   "$(git -C "$box/lore" rev-list --count HEAD)" "1"
same "plain: the KB files came back"       "$(cat "$box/lore/knowledge/adrs/0001-x.md")" "adr"

# THE regression: the backup must never be tracked, and the split must be a deletion
# rather than a rename into the backup's path.
absent "plain: no backup left in the worktree" "$box/lore.split-backup"
lacks "plain: nothing named split-backup is tracked" \
      "$(git -C "$box" ls-tree -r --name-only HEAD)" "split-backup"
lacks "plain: no backup in any commit, at any revision" \
      "$(git -C "$box" log --all --name-only --format= )" "split-backup"
same "plain: lore/ is untracked in the parent" \
     "$(git -C "$box" ls-files lore | wc -l)" "0"
same "plain: and it is ignored, so it is not reported" \
     "$(git -C "$box" status --porcelain --ignored=no -- lore | wc -l)" "0"
has  "plain: .gitignore names the path" "$(cat "$box/.gitignore")" "/lore/"

# --- the template's shape: catch-all plus an allowlist line ----------------------
box=$(setup template $'/*\n!/.gitignore\n!/lore/\n!/scripts/\n!/household.json\n!/README.md\n')
run "$box" $'1\ny\n'
same "template: exits 0"                     "$status" "0"
clean "template: parent worktree is clean"   "$box"
lacks "template: the allowlist line is gone" "$(cat "$box/.gitignore")" '!/lore/'
same "template: the catch-all already ignores it, so no rule was appended" \
     "$(grep -cx '/lore/' "$box/.gitignore")" "0"
is_dir "template: lore/ is its own repo"     "$box/lore/.git"

# --- an unrelated dirty file must not be swept into the split commit -------------
box=$(setup scoped)
echo "work in progress" > "$box/NOTES.md"
echo "edited" >> "$box/README.md"
run "$box" $'1\ny\n'
same "scoped: exits 0"                    "$status" "0"
lacks "scoped: the untracked file was not committed" \
      "$(git -C "$box" show --name-only --format= HEAD)" "NOTES.md"
lacks "scoped: the unrelated edit was not committed" \
      "$(git -C "$box" show --name-only --format= HEAD)" "README.md"
has  "scoped: the untracked file is still there" \
     "$(git -C "$box" status --porcelain)" "NOTES.md"

# --- refusals --------------------------------------------------------------------
box=$(setup no-lore)
rm -rf "$box/lore"
run "$box" $'1\ny\n'
same "no-lore: exits 1"        "$status" "1"
has  "no-lore: says why"       "$out" "No lore/ directory"

box=$(setup already-split)
git -C "$box/lore" init -q -b main .
run "$box" $'1\ny\n'
same "already-split: exits 1"  "$status" "1"
has  "already-split: says why" "$out" "already a separate sibling"

# --- declining at the prompt changes nothing -------------------------------------
box=$(setup aborted)
before=$(git -C "$box" rev-parse HEAD)
run "$box" $'1\nn\n'
same "aborted: exits 1"                    "$status" "1"
has  "aborted: says so"                    "$out" "Aborted."
same "aborted: no new commit"              "$(git -C "$box" rev-parse HEAD)" "$before"
clean "aborted: worktree untouched"        "$box"
is_dir "aborted: lore/ is still inline"    "$box/lore/knowledge"
absent "aborted: lore/ did not become a repo" "$box/lore/.git"

echo ""
echo "  $passed passed, $failed failed"
(( failed == 0 )) || exit 1
