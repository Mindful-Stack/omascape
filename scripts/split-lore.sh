#!/bin/bash
set -euo pipefail

# Promote the inline `lore/` to a separate sibling git repo.
# Usage: ./scripts/split-lore.sh [REMOTE_URL]
#        REMOTE_URL is optional; if omitted, prompts interactively.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
LORE="$WORKSPACE/lore"
REMOTE="${1:-}"

if [ ! -d "$LORE" ]; then
    echo "ERROR: No lore/ directory at $LORE" >&2
    exit 1
fi
if [ -d "$LORE/.git" ]; then
    echo "ERROR: $LORE already has its own .git/ — already a separate sibling" >&2
    exit 1
fi

# --- Resolve remote ---
if [ -z "$REMOTE" ]; then
    echo "Inline lore/ is currently tracked in this workspace's git history."
    echo "Where should the extracted lore repo's origin point?"
    echo ""
    echo "  [1] local-only (no remote; you'll set one up later)"
    echo "  [2] create a new GitHub repo via 'gh repo create' (requires gh CLI)"
    echo "  [3] paste a remote URL I already have"
    echo "  [q] cancel"
    echo ""
    read -p "Choice: " CHOICE
    case "$CHOICE" in
        1) REMOTE="" ;;
        2)
            command -v gh >/dev/null 2>&1 || { echo "gh CLI not installed; aborting" >&2; exit 1; }
            read -p "Target repo name (e.g. you/my-workspace-lore): " GH_NAME
            read -p "Visibility (public/private) [private]: " GH_VIS
            GH_VIS="${GH_VIS:-private}"
            echo "Will run: gh repo create $GH_NAME --$GH_VIS"
            read -p "Proceed? [y/N]: " CONFIRM
            [ "$CONFIRM" = "y" ] || { echo "Aborted."; exit 1; }
            gh repo create "$GH_NAME" --"$GH_VIS" >/dev/null
            REMOTE="git@github.com:$GH_NAME.git"
            echo "Created $GH_NAME"
            ;;
        3)
            read -p "Remote URL: " REMOTE
            ;;
        q|Q) echo "Cancelled."; exit 0 ;;
        *) echo "Invalid choice." >&2; exit 1 ;;
    esac
fi

# --- Confirm before destructive ops ---
echo ""
echo "About to:"
echo "  1. Copy lore/ to a temporary directory OUTSIDE this worktree"
echo "  2. Stop tracking lore/ here, and add it to .gitignore (one commit)"
echo "  3. Restore lore/ from the copy as its own git repo"
[ -n "$REMOTE" ] && echo "  4. Set origin = $REMOTE and push"
echo "  5. Point household.json at the remote"
echo ""
echo "This does NOT rewrite history: earlier commits still contain lore/."
echo ""
read -p "Proceed? [y/N]: " CONFIRM
[ "$CONFIRM" = "y" ] || { echo "Aborted."; exit 1; }

# --- Execute ---
cd "$WORKSPACE"

# The backup lives outside the worktree on purpose. Kept inside it, any `git add`
# wide enough to catch it commits the whole KB a second time under the backup's
# path -- which is a rename, not a removal, so the split commit does the opposite
# of what it says. The trap fires on failure too: an aborted run must not leave
# the only copy of the KB in a temp directory nobody knows about.
BACKUP_DIR="$(mktemp -d)"
cleanup() {
    # Only shout when the worktree copy is actually gone. A run interrupted during
    # the copy itself leaves a partial backup AND the original, and pointing the
    # user at the partial one would be the wrong advice.
    if [ -d "$BACKUP_DIR/lore" ] && [ ! -d "$WORKSPACE/lore" ]; then
        echo "" >&2
        echo "Interrupted. Your lore/ content is safe at: $BACKUP_DIR/lore" >&2
        echo "Move it back to $WORKSPACE/lore before re-running." >&2
        return
    fi
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "[1/5] Copying lore/ to $BACKUP_DIR ..."
cp -r lore "$BACKUP_DIR/lore"

echo "[2/5] Untracking lore/ here and ignoring the path..."
rm -rf lore

# Three starting points, one end state: `lore/` must be ignored when this returns.
# The template ships a catch-all `/*` plus a `!/lore/` allowlist, so dropping the
# allowlist line is enough there. A repository that kept its own .gitignore (this
# one does -- the catch-all would have silently ignored every new spec and test)
# has no catch-all to fall back on and needs the rule written out.
if grep -qx '!/lore/' .gitignore 2>/dev/null; then
    grep -vx '!/lore/' .gitignore > .gitignore.tmp && mv .gitignore.tmp .gitignore
fi
# --no-index is load-bearing: without it `git check-ignore` reports any path still
# in the index as NOT ignored, and lore/'s removal is not staged yet -- so the
# template's catch-all would go unnoticed and a redundant rule be appended.
if ! git check-ignore -q --no-index lore; then
    printf '\n# lore/ is its own repo now (scripts/split-lore.sh)\n/lore/\n' >> .gitignore
fi

# Scoped pathspecs, never `git add -A`: this commit stages the removal of lore/
# and the .gitignore rule, and nothing else a dirty worktree happens to contain.
git add -A -- lore .gitignore
git commit -m "split: lore becomes a sibling repo"

echo "[3/5] Restoring as a sibling repo..."
mv "$BACKUP_DIR/lore" lore
cd lore
git init -b main --quiet
git add -A
git commit -m "initial lore" --quiet
cd "$WORKSPACE"

if [ -n "$REMOTE" ]; then
    echo "[4/5] Wiring remote: $REMOTE"
    git -C lore remote add origin "$REMOTE"
    git -C lore push -u origin main --quiet
fi

echo "[5/5] Updating household.json..."

# household.json: if a remote was provided, set the lore entry's url
if [ -n "$REMOTE" ]; then
    REMOTE="$REMOTE" node -e "
        const fs = require('fs');
        const path = './household.json';
        const m = JSON.parse(fs.readFileSync(path, 'utf8'));
        const kb = m.knowledge_base || 'lore';
        const entry = m.repos.find(r => r.name === kb);
        if (entry) entry.url = process.env.REMOTE;
        fs.writeFileSync(path, JSON.stringify(m, null, 2) + '\n');
    "
fi

# Nothing to say when no remote was given -- an empty commit would fail the run
# under `set -e` after every destructive step has already succeeded.
git add -- household.json
if git diff --cached --quiet; then
    echo "      (no remote given; household.json unchanged)"
else
    git commit -m "split: point household.json at the lore remote"
fi

echo ""
echo "Done. lore/ is now a sibling git repo."
if [ -n "$REMOTE" ]; then
    echo "  Remote: $REMOTE"
fi
