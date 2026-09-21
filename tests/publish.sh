#!/usr/bin/env bash
set -uo pipefail                      # deliberately not -e: cases run failures
# Stub-free harness for scripts/publish.sh. Every case builds a throwaway repository in
# $work whose shape mirrors this one -- a runtime surface, a development surface, and a
# `main` that is an ancestor of `dev` -- then runs the real script against it and asserts
# on the resulting git objects. No network, no remote, nothing checked out.
#
# What this exists for: the published tree is the artifact every `omarchy plugin add` user
# installs, and it is assembled by plumbing rather than by a checkout, so a mistake here
# produces a commit that looks plausible and installs broken. The guards are the point of
# the script; the cases below are mostly about proving each guard actually fires.

src=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$src/scripts/publish.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Omarchy's own validator only exists on an Omarchy box, and the synthetic plugins below are
# not built to satisfy its schema -- so the suite always supplies its own. A case that cares
# about the validator overrides this per run.
printf '#!/bin/bash\nexit 0\n'                          > "$work/validate-ok"
printf '#!/bin/bash\necho "rejected: bad tree" >&2\nexit 1\n' > "$work/validate-no"
chmod +x "$work/validate-ok" "$work/validate-no"

passed=0
failed=0
ok()  { printf '  ok   %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2-}"; failed=$((failed + 1)); }
same()  { if [[ $2 == "$3" ]];   then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1" "output lacks [$3]: $2"; fi; }
lacks() { if [[ $2 != *"$3"* ]]; then ok "$1"; else bad "$1" "output should not contain [$3]: $2"; fi; }
clean() { local st; st=$(git -C "$2" status --porcelain); if [[ -z $st ]]; then ok "$1"; else bad "$1" "worktree not clean:"$'\n'"$st"; fi; }

# setup <case-name>: a throwaway repository whose `main` is a published-shaped ancestor of
# `dev`, and whose `dev` carries the full project. Echoes the path.
setup() {
    local box="$work/$1"
    mkdir -p "$box/scripts" "$box/tests" "$box/docs/screenshots" "$box/lore/knowledge" \
             "$box/.github/ISSUE_TEMPLATE" "$box/.github/workflows"
    cp "$script" "$box/scripts/publish.sh"

    # --- the runtime surface
    cat > "$box/Overview.qml" <<'QML'
import QtQuick
import "logic.js" as Logic
Item { }
QML
    echo 'var x = 1;'                                  > "$box/logic.js"
    printf '{\n  "id": "x.y",\n  "version": "1.0.0",\n  "entryPoints": { "overlay": "Overview.qml" }\n}\n' \
                                                       > "$box/manifest.json"
    printf 'RIFF\x00\x00WEBPfake\x00binary\n'          > "$box/preview.webp"
    echo 'MIT'                                         > "$box/LICENSE"
    printf '# Editor cruft\n*.bak\n'                   > "$box/.gitignore"
    cat > "$box/README.md" <<'MD'
# Thing

![shot](docs/screenshots/demo.gif)

## Install

Add it.

## Contributing

Run `mise run dev:link`, which prints `systemctl --user show-environment` output.

### Testing

`mise run test`.

## License

MIT — see [LICENSE](LICENSE).
MD

    # --- community health
    echo '# Conduct'      > "$box/CODE_OF_CONDUCT.md"
    echo '# Contributing' > "$box/CONTRIBUTING.md"
    echo '# Security'     > "$box/SECURITY.md"
    echo 'name: bug'      > "$box/.github/ISSUE_TEMPLATE/bug_report.yml"
    echo '## What'        > "$box/.github/PULL_REQUEST_TEMPLATE.md"
    printf 'name: ci\njobs:\n  t:\n    steps:\n      - run: sudo apt-get install -y lua5.4\n' \
                          > "$box/.github/workflows/ci.yml"

    # --- the development surface, none of which may reach the published tree
    echo '# CLAUDE.md'                 > "$box/CLAUDE.md"
    echo '# Design'                    > "$box/DESIGN.md"
    echo 'gif'                         > "$box/docs/screenshots/demo.gif"
    echo '# Spec'                      > "$box/docs/spec.md"
    echo 'curl -fsSL x | bash'         > "$box/scripts/setup.sh"
    echo 'test'                        > "$box/tests/run.sh"
    echo '# Installer or setup file'   > "$box/lore/knowledge/0001-install.md"
    printf '[tasks.test]\nrun = "x"\n' > "$box/mise.toml"

    git -C "$box" init -q -b main .
    git -C "$box" config user.email t@t
    git -C "$box" config user.name T
    # `main` starts as an ancestor carrying only the runtime files: that is the real shape,
    # and it is what makes the ancestry guard meaningful.
    git -C "$box" add Overview.qml logic.js manifest.json preview.webp LICENSE README.md
    git -C "$box" commit -qm "initial release"
    git -C "$box" checkout -q -b dev
    # dev carries the bump: publishing a changed tree under the already-published
    # version is refused, so the fixture has to look like a real release train.
    sed -i 's/"1.0.0"/"1.0.1"/' "$box/manifest.json"
    git -C "$box" add -A
    git -C "$box" commit -qm "the project"
    echo "$box"
}

# run <box> [args...]: the script against that box's dev. Sets $out and $status.
run() {
    local box=$1; shift
    out=$(cd "$box" && OMARCHY_PLUGIN_VALIDATE="${VALIDATOR:-$work/validate-ok}" \
        bash scripts/publish.sh --onto main --into main ${VERSION_FLAG:-} "$@" 2>&1)
    status=$?
}

# tree <box>: the published tree's paths, one per line.
tree() { git -C "$1" ls-tree -r --name-only main; }

# --- the ordinary publish ---------------------------------------------------------------
box=$(setup plain)
before=$(git -C "$box" rev-parse main)
run "$box"
same "plain: exits 0"                       "$status" "0"
has  "plain: names the version"             "$out" "1.0.1"
clean "plain: the dev worktree is untouched" "$box"
same "plain: dev did not move"              "$(git -C "$box" rev-parse HEAD)" "$(git -C "$box" rev-parse dev)"
same "plain: still on dev"                  "$(git -C "$box" rev-parse --abbrev-ref HEAD)" "dev"

# The release commit must be a fast-forward from the old tip: `omarchy plugin update` does
# `git merge --ff-only`, so a commit that is not a descendant strands every installed user.
same "plain: the release commit's parent is the old tip" \
     "$(git -C "$box" rev-parse main^)" "$before"
same "plain: it is one commit, not a squash of many" \
     "$(git -C "$box" rev-list --count "$before"..main)" "1"

published=$(tree "$box")
for f in Overview.qml logic.js manifest.json preview.webp LICENSE README.md .gitignore \
         CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md \
         .github/ISSUE_TEMPLATE/bug_report.yml .github/PULL_REQUEST_TEMPLATE.md; do
    has "plain: publishes $f" "$published" "$f"
done
# The whole point: the development surface does not ship.
for f in CLAUDE.md DESIGN.md mise.toml docs/ scripts/ tests/ lore/ .github/workflows; do
    lacks "plain: does not publish $f" "$published" "$f"
done
same "plain: publishes exactly 12 files" "$(printf '%s\n' "$published" | wc -l)" "12"

readme=$(git -C "$box" show main:README.md)
has   "plain: README keeps the user-facing half"        "$readme" "## Install"
has   "plain: README keeps the licence"                 "$readme" "## License"
has   "plain: README points contributors at dev"        "$readme" "/tree/dev"
lacks "plain: README drops the dev-only instructions"   "$readme" "mise run dev:link"
lacks "plain: README drops the sub-headings under it"   "$readme" "### Testing"
has   "plain: screenshots resolve against dev"          "$readme" \
      "https://raw.githubusercontent.com/Mindful-Stack/omascape/dev/docs/screenshots/demo.gif"

has "plain: records the source commit it was built from" \
    "$(git -C "$box" log -1 --format=%B main)" "Source-commit: $(git -C "$box" rev-parse dev)"

# --- idempotence: the same source twice is not two commits -------------------------------
run "$box"
same "repeat: exits 0"            "$status" "0"
has  "repeat: says there is nothing to do" "$out" "nothing to publish"
same "repeat: main did not move"  "$(git -C "$box" rev-list --count "$before"..main)" "1"

# --- the SECOND train ---------------------------------------------------------------------
# The release commit is generated, so `main` is never an ancestor of `dev` again. An
# ancestry check against the branch would have blocked every release after the first; the
# Source-commit trailer is what makes the train repeatable.
echo 'var x = 2;' > "$box/logic.js"
sed -i 's/"1.0.1"/"1.0.2"/' "$box/manifest.json"
git -C "$box" commit -qam "a second release's worth of work"
run "$box"
same "second: exits 0"                  "$status" "0"
same "second: main gained one commit"   "$(git -C "$box" rev-list --count "$before"..main)" "2"
same "second: the change shipped"       "$(git -C "$box" show main:logic.js)" "var x = 2;"
has  "second: records the new source"   "$(git -C "$box" log -1 --format=%B main)" \
     "Source-commit: $(git -C "$box" rev-parse dev)"

# A commit made straight on the release branch has no trailer, so the next publish falls
# back to asking whether the branch itself is behind -- and refuses, rather than quietly
# overwriting whatever was hand-landed there.
git -C "$box" checkout -q main
echo 'MIT (2026)' > "$box/LICENSE"
git -C "$box" commit -qam "a hotfix landed straight on the release branch"
git -C "$box" checkout -q dev
run "$box"
same "hand-landed: exits 1"  "$status" "1"
has  "hand-landed: says why" "$out" "not an ancestor"

# --- --dry-run writes nothing ------------------------------------------------------------
box=$(setup dry)
before=$(git -C "$box" rev-parse main)
run "$box" --dry-run
same "dry: exits 0"              "$status" "0"
has  "dry: says so"              "$out" "nothing written"
same "dry: main did not move"    "$(git -C "$box" rev-parse main)" "$before"

# --- the guards --------------------------------------------------------------------------
# Each of these produces a tree that looks plausible and is wrong, which is why they are
# failures rather than warnings.

box=$(setup bad-entry)
sed -i 's/Overview.qml/Missing.qml/' "$box/manifest.json"
git -C "$box" commit -qam "break the entry point"
run "$box"
same "bad-entry: exits 1"  "$status" "1"
has  "bad-entry: says why" "$out" "entry point is not published"

box=$(setup bad-import)
printf 'import QtQuick\nimport "helpers/util.js" as U\nItem { }\n' > "$box/Overview.qml"
git -C "$box" commit -qam "import something that will not ship"
run "$box"
same "bad-import: exits 1"  "$status" "1"
has  "bad-import: names the import" "$out" "helpers/util.js"

box=$(setup risky)
echo '// run: curl https://example.com/x | bash' >> "$box/logic.js"
git -C "$box" commit -qam "add a pattern the marketplace scanner flags"
run "$box"
same "risky: exits 1"        "$status" "1"
has  "risky: names the file" "$out" "logic.js"
has  "risky: says what it costs" "$out" "security review"

box=$(setup missing-shot)
git -C "$box" rm -q docs/screenshots/demo.gif
git -C "$box" commit -qm "drop the screenshot the README links"
run "$box"
same "missing-shot: exits 1"  "$status" "1"
has  "missing-shot: says why" "$out" "screenshot that is not in"

# `main` ahead of `dev` is the real divergence this repository had: publishing across it
# would have rolled the plugin back a version without a word.
box=$(setup diverged)
git -C "$box" checkout -q main
echo 'MIT (2026)' > "$box/LICENSE"
git -C "$box" commit -qam "a hotfix that only landed on main"
git -C "$box" checkout -q dev
run "$box"
same "diverged: exits 1"  "$status" "1"
has  "diverged: says which way round" "$out" "not an ancestor"

# Omarchy runs this validator on update and hard-resets the user when it fails, so a tree it
# rejects must never become a commit -- the user would keep a working plugin and silently
# stop receiving updates.
box=$(setup rejected)
before=$(git -C "$box" rev-parse main)
VALIDATOR="$work/validate-no" run "$box"
same "rejected: exits 1"       "$status" "1"
has  "rejected: says why"      "$out" "omarchy-plugin-validate rejects"
has  "rejected: passes the validator's own message through" "$out" "rejected: bad tree"
same "rejected: main did not move" "$(git -C "$box" rev-parse main)" "$before"

box=$(setup validated)
run "$box"
same "validated: exits 0"      "$status" "0"
has  "validated: says it ran"  "$out" "omarchy-plugin-validate passed"

# No validator is not a pass, and the run says so rather than going quiet.
box=$(setup unvalidated)
VALIDATOR=/nonexistent/omarchy-plugin-validate run "$box"
same "unvalidated: still exits 0" "$status" "0"
has  "unvalidated: says it skipped" "$out" "SKIPPED omarchy-plugin-validate"

# `git update-ref` moves a branch regardless of who has it checked out, and the worktree that
# did is then on the new commit with the old files on disk -- which reads as a full set of
# staged additions, every one a development file this release had just removed. Committing
# there would republish the whole dev tree.
box=$(setup checked-out)
before=$(git -C "$box" rev-parse main)
git -C "$box" worktree add -q "$work/checked-out-release" main
run "$box"
same "checked-out: exits 1"        "$status" "1"
has  "checked-out: names the path" "$out" "$work/checked-out-release"
has  "checked-out: says what it would have done" "$out" "files this release removes"
same "checked-out: main did not move" "$(git -C "$box" rev-parse main)" "$before"
clean "checked-out: that worktree is untouched" "$work/checked-out-release"
git -C "$box" worktree remove --force "$work/checked-out-release"

# Standing on the release branch is the same mistake with a more useful answer. The script is
# invoked by absolute path here: `main` is the published tree, so it has no scripts/ to run.
box=$(setup standing-on-it)
git -C "$box" checkout -q main
out=$(cd "$box" && OMARCHY_PLUGIN_VALIDATE="$work/validate-ok" \
    bash "$script" --source dev --onto main --into main 2>&1)
status=$?
same "standing-on-it: exits 1"  "$status" "1"
has  "standing-on-it: says where to stand" "$out" "publish from the development branch"

# A local release branch that is merely stale is the common case -- a fetch updates the
# remote-tracking ref and leaves the local branch behind -- and "not at origin/main" said
# nothing about which of the two problems it was or how to get out of it.
#
# `published` stands in for origin/main here, so that `main` can be the stale local branch.
# dev has to move between the two runs or the idempotence check answers first.
pub() {
    out=$(cd "$1" && OMARCHY_PLUGIN_VALIDATE="$work/validate-ok" \
        bash scripts/publish.sh --onto "$2" --into "$3" 2>&1)
    status=$?
}
box=$(setup stale)
pub "$box" main published
same "stale: the first release lands" "$status" "0"
echo 'var x = 2;' > "$box/logic.js"
sed -i 's/"1.0.1"/"1.0.2"/' "$box/manifest.json"
git -C "$box" commit -qam "work that the next release carries"

pub "$box" published main
same "stale: exits 1"                "$status" "1"
has  "stale: counts the gap"         "$out" "local main is 1 behind published"
has  "stale: gives the one-line fix" "$out" "git branch -f main published"

# Ahead is a different problem with the same symptom, and must not suggest clobbering it.
git -C "$box" checkout -q main
echo 'MIT (2026)' > "$box/LICENSE"
git -C "$box" commit -qam "an unpublished commit on the release branch"
git -C "$box" checkout -q dev
pub "$box" published main
same  "ahead: exits 1"                  "$status" "1"
has   "ahead: says which way"           "$out" "1 ahead of published"
lacks "ahead: does not suggest a force" "$out" "git branch -f"

# The marketplace lists one version per commit, so two different trees published as the same
# version leave it describing the wrong one. A warning under sixty lines of diffstat is a
# warning nobody reads, so this refuses.
box=$(setup unbumped)
before=$(git -C "$box" rev-parse main)
sed -i 's/"1.0.1"/"1.0.0"/' "$box/manifest.json"          # back to what main already ships
echo 'var x = 3;' > "$box/logic.js"                       # but the tree really did change
git -C "$box" commit -qam "a release that forgot the bump"
run "$box"
same "unbumped: exits 1"           "$status" "1"
has  "unbumped: says what to do"   "$out" "bump it, or pass --allow-same-version"
same "unbumped: main did not move" "$(git -C "$box" rev-parse main)" "$before"

VERSION_FLAG=--allow-same-version run "$box"
same "unbumped: the escape publishes"  "$status" "0"
has  "unbumped: and says it used it"   "$out" "republishing 1.0.0 unchanged"

# An unchanged tree is a no-op, not a version problem -- the idempotence check answers first.
box=$(setup no-op)
run "$box"
same "no-op: the first release lands" "$status" "0"
run "$box"
same "no-op: exits 0"                 "$status" "0"
has  "no-op: says nothing to publish" "$out" "nothing to publish"
lacks "no-op: does not complain about the version" "$out" "bump it"

box=$(setup dirty)
echo 'work in progress' > "$box/Overview.qml"
run "$box"
same "dirty: exits 1"  "$status" "1"
has  "dirty: says why" "$out" "worktree is dirty"

# ...but an explicit ref is unambiguous, so the same dirty box publishes from a named commit.
run "$box" --source dev
same "dirty: --source publishes anyway" "$status" "0"

echo ""
echo "  $passed passed, $failed failed"
(( failed == 0 )) || exit 1
