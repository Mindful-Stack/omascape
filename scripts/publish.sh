#!/bin/bash
set -euo pipefail
# Build the published plugin tree and record it as a commit on the release branch.
#
# `omarchy plugin add` does a bare `git clone` of the default branch and `omarchy plugin
# update` fast-forwards onto its tip, so the default branch IS the artifact every user
# installs -- and the marketplace reviews the whole repository, not the subset the plugin
# loads (ADR-0010). Development therefore lives on `dev` and `main` carries only what the
# overlay needs at runtime plus the community health files GitHub reads from the default
# branch.
#
# The commit is built with plumbing against a temporary index: no branch is checked out, no
# worktree is touched, and nothing is pushed. The result is an ordinary commit whose parent
# is the current release-branch tip, so installed users fast-forward onto it -- the files
# this drops are files their plugin never loaded.
#
# Usage:
#   scripts/publish.sh [--source <ref>] [--onto <ref>] [--into <branch>] [--dry-run]
#
# Defaults: --source HEAD (worktree must be clean), --onto origin/main, --into main.

die() { printf 'publish: %s\n' "$*" >&2; exit 1; }

SOURCE=HEAD
ONTO=origin/main
INTO=main
DRY=0
SOURCE_GIVEN=0

while (( $# )); do
    case $1 in
        --source) SOURCE=${2-}; SOURCE_GIVEN=1; shift 2 ;;
        --onto)   ONTO=${2-};   shift 2 ;;
        --into)   INTO=${2-};   shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

src=$(git rev-parse --verify "${SOURCE}^{commit}" 2>/dev/null) || die "no such source ref: $SOURCE"
onto=$(git rev-parse --verify "${ONTO}^{commit}" 2>/dev/null) || die "no such release ref: $ONTO"

# Nothing already published may be rolled back. `main` carried two commits `dev` had never
# seen the first time this ran, and the built tree would have taken the plugin back a
# version without saying so.
#
# The release commits are generated, so `main` is NOT an ancestor of `dev` and never becomes
# one -- checking that directly would block every train after the first. What has to hold is
# that the source the last release was built from is behind the source this one is built
# from, which is what the Source-commit trailer records. A tip without a trailer was not
# written by this script (the first publish, or a commit made straight on the release
# branch), and there the ancestry of the branch itself is the honest question.
prev_src=$(git log -1 --format=%B "$onto" | sed -nE 's/^Source-commit:[[:space:]]*([0-9a-f]{40})[[:space:]]*$/\1/p' | tail -n 1)
if [[ -n $prev_src ]] && git cat-file -e "${prev_src}^{commit}" 2>/dev/null; then
    git merge-base --is-ancestor "$prev_src" "$src" || die \
        "$ONTO was published from $(git rev-parse --short "$prev_src"), which is not an ancestor of $SOURCE"
else
    git merge-base --is-ancestor "$onto" "$src" \
        || die "$ONTO is not an ancestor of $SOURCE -- merge $ONTO into $SOURCE first"
fi

# A dirty worktree silently publishes the committed state rather than what the maintainer is
# looking at. Only checked when the source is HEAD -- an explicit ref is unambiguous.
if (( ! SOURCE_GIVEN )) && [[ -n $(git status --porcelain) ]]; then
    die "worktree is dirty; commit or stash first (or pass --source <ref>)"
fi

# ---- the published set -------------------------------------------------------------------
# Runtime: every root .qml plus the pure-JS logic they import, the manifest, the preview and
# the licence. Community health: the three files, plus the issue and PR templates -- GitHub
# reads those from the DEFAULT branch only, so they do not work from `dev`.
# README.md is published through a transform (below), so it is not listed here.
#
# `.github/workflows/` is deliberately NOT published. Workflows run from the branch the event
# happened on, so CI works from `dev` either way, and ci.yml installs Lua with `sudo apt-get`
# -- a line that means nothing on a branch with no tests and everything to a scanner reading
# the installed tree.
runtime_files=(logic.js manifest.json preview.webp LICENSE .gitignore)
health_files=(CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md)

published=()
while IFS= read -r p; do published+=("$p"); done < <(git ls-tree --name-only "$src" | grep -E '\.qml$' || true)
(( ${#published[@]} )) || die "no root .qml files in $SOURCE -- refusing to publish an empty overlay"

for p in "${runtime_files[@]}" "${health_files[@]}"; do
    git cat-file -e "$src:$p" 2>/dev/null || die "missing from $SOURCE: $p"
    published+=("$p")
done
while IFS= read -r p; do published+=("$p"); done < <(
    git ls-tree -r --name-only "$src" -- .github/ISSUE_TEMPLATE .github/PULL_REQUEST_TEMPLATE.md)

git cat-file -e "$src:README.md" 2>/dev/null || die "missing from $SOURCE: README.md"

# ---- README transform --------------------------------------------------------------------
# The published README keeps the user-facing half and everything from `## License` on. The
# `## Contributing` section documents a checkout that main does not contain -- `mise run
# dev:link`, `scripts/`, `tests/`, `docs/specs/` -- and its sample `dev:link` output is the
# one place in the runtime surface that trips the marketplace's service-management pattern.
# It is replaced by a pointer at `dev`, where all of it is true.
RAW=https://raw.githubusercontent.com/Mindful-Stack/omascape/dev

readme_published() {
    git show "$src:README.md" | sed "s|](docs/|]($RAW/docs/|g" | awk '
        /^## Contributing$/ { skipping = 1; print_pointer(); next }
        skipping && /^## / { skipping = 0 }
        !skipping { print }
        function print_pointer() {
            print "## Contributing"
            print ""
            print "`main` is the published plugin tree: the files Omarchy installs and nothing else."
            print "Development happens on **[`dev`](https://github.com/Mindful-Stack/omascape/tree/dev)**,"
            print "which carries the specs, tests, tooling and knowledge base."
            print ""
            print "Start with [CONTRIBUTING.md](CONTRIBUTING.md)."
            print ""
        }'
}

readme=$(readme_published)
[[ $readme == *"## Contributing"* ]] || die "README transform lost the Contributing section"
[[ $readme == *"## License"* ]]      || die "README transform lost the License section"

# The screenshots stay on `dev` -- demo.gif alone is 4.5 MB, nine times the whole runtime
# tree -- so the published README points at raw.githubusercontent. That link is only as
# good as the path, and a renamed screenshot would break the repository's front page
# silently, so every rewritten target is checked against the source tree.
while IFS= read -r img; do
    git cat-file -e "$src:$img" 2>/dev/null || die "README links a screenshot that is not in $SOURCE: $img"
done < <(printf '%s\n' "$readme" | grep -oE "$RAW/[^)]+" | sed "s|^$RAW/||" | sort -u)

# ---- guards ------------------------------------------------------------------------------
# Each of these has a way of being wrong that produces a tree which looks fine and installs
# broken, so they fail the publish rather than warn.

is_published() { local n; for n in "${published[@]}"; do [[ $n == "$1" ]] && return 0; done; return 1; }

# The entry point the shell actually loads.
entry=$(git show "$src:manifest.json" | grep -oE '"overlay"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/')
[[ -n $entry ]] || die "manifest.json declares no overlay entry point"
is_published "$entry" || die "manifest entry point is not published: $entry"

# Every local import must resolve inside the published set, or the overlay dies at load with
# a QML error no test on `dev` would ever see.
for f in "${published[@]}"; do
    [[ $f == *.qml ]] || continue
    while IFS= read -r target; do
        is_published "$target" || die "$f imports '$target', which is not published"
    done < <(git show "$src:$f" | sed -nE 's/^[[:space:]]*import[[:space:]]+"([^"]+)".*/\1/p')
done

# The marketplace's automated baseline reads the published tree. A hit here is not
# necessarily a defect, but it is always a listing delay, so it stops the train.
risk='systemctl|curl[[:space:]]|wget[[:space:]]|git clone|[^a-z]sudo[[:space:]]|pacman|makepkg|install\.sh|setup\.sh'
hits=$(git grep -nIE "$risk" "$src" -- "${published[@]}" | sed "s|^$src:|  |" || true)
match=$(printf '%s\n' "$readme" | grep -nE "$risk" || true)
[[ -n $match ]] && hits+=$'\n'"  README.md (transformed):"$'\n'"$match"
if [[ -n $hits ]]; then
    printf 'publish: the published tree matches the marketplace baseline patterns:\n\n%s\n' "$hits" >&2
    die "fix these or the listing stalls in security review"
fi

version=$(git show "$src:manifest.json" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/')
[[ -n $version ]] || die "manifest.json declares no version"
prev_version=$(git show "$onto:manifest.json" 2>/dev/null | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' || true)
if [[ -n $prev_version && $prev_version == "$version" ]]; then
    printf 'publish: warning -- manifest version is still %s; the marketplace lists a version per commit\n' "$version" >&2
fi

# ---- build the tree ----------------------------------------------------------------------
# A temporary index, not a subshell: an EXIT trap fires inside `( )` too, and would delete
# the scratch directory before the parent could read the tree back out of it.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export GIT_INDEX_FILE="$tmp/index"
git read-tree --empty
for f in "${published[@]}"; do
    mode=$(git ls-tree "$src" -- "$f" | awk '{print $1}')
    [[ -n $mode ]] || die "cannot stat $f in $SOURCE"
    git update-index --add --cacheinfo "$mode,$(git rev-parse "$src:$f"),$f"
done
blob=$(printf '%s\n' "$readme" | git hash-object -w --stdin)
git update-index --add --cacheinfo "100644,$blob,README.md"
tree=$(git write-tree)
unset GIT_INDEX_FILE

# Omarchy runs its own validator as step 4 of `plugin update` and does `git reset --hard
# ORIG_HEAD` when it fails -- so a tree that fails here does not break loudly, it silently
# stops every installed user from ever receiving another update. Run it against the real
# tree while we still have one to throw away.
VALIDATE=${OMARCHY_PLUGIN_VALIDATE:-}
[[ -n $VALIDATE ]] || VALIDATE=$(command -v omarchy-plugin-validate 2>/dev/null || true)
[[ -n $VALIDATE || ! -x /usr/share/omarchy/bin/omarchy-plugin-validate ]] \
    || VALIDATE=/usr/share/omarchy/bin/omarchy-plugin-validate
if [[ -n $VALIDATE && -x $VALIDATE ]]; then
    stage="$tmp/tree"; mkdir -p "$stage"
    git archive "$tree" | tar -x -C "$stage"
    "$VALIDATE" "$stage" || die "omarchy-plugin-validate rejects the published tree"
    echo "publish: omarchy-plugin-validate passed"
else
    echo "publish: SKIPPED omarchy-plugin-validate (not installed) — the tree is unverified against Omarchy" >&2
fi

if [[ $tree == "$(git rev-parse "$onto^{tree}")" ]]; then
    echo "publish: $ONTO already carries this exact tree — nothing to publish"
    exit 0
fi

echo "publish: $version from $(git rev-parse --short "$src") — ${#published[@]} files + README"
git diff --stat "$onto^{tree}" "$tree" | tail -n 1

if (( DRY )); then
    echo
    git diff --name-status "$onto^{tree}" "$tree"
    echo
    echo "publish: --dry-run, nothing written"
    exit 0
fi

commit=$(git commit-tree "$tree" -p "$onto" -m "release: publish $version

Runtime-only tree built by scripts/publish.sh. Development history is on \`dev\`;
this branch is the artifact Omarchy installs.

Source-commit: $src")

# `git update-ref` will happily move a branch that a worktree has checked out, and that
# worktree is then sitting on the new commit with the old files still on disk -- which git
# reads as "the user staged 162 additions", every one of them a development file the release
# had just removed. A commit there republishes the entire dev tree to main. Refuse instead.
checked_out=$(git worktree list --porcelain | awk -v b="refs/heads/$INTO" '
    /^worktree /{ path = substr($0, 10) }
    /^branch /   { if (substr($0, 8) == b) { print path; exit } }')
if [[ -n $checked_out ]]; then
    if [[ $checked_out == "$(git rev-parse --show-toplevel)" ]]; then
        die "you are on $INTO; publish from the development branch instead"
    fi
    die "$INTO is checked out at $checked_out; publishing would leave that worktree staging the files this release removes"
fi

# Only move a local release branch that is exactly where we branched from. Anything else is
# a divergence the maintainer has to look at, not something to fast-forward over.
if git rev-parse --verify "refs/heads/$INTO" >/dev/null 2>&1; then
    [[ $(git rev-parse "refs/heads/$INTO") == "$onto" ]] \
        || die "local $INTO is not at $ONTO; sort that out before publishing"
fi
git update-ref "refs/heads/$INTO" "$commit"

echo "publish: wrote $(git rev-parse --short "$commit") to $INTO"
echo "         git push origin $INTO && git tag -a v$version $commit && git push origin v$version"
