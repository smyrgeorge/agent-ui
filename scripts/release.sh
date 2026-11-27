#!/usr/bin/env bash
# A release: the version in agent-ui.el's header, tagged vX.Y.Z (an annotated
# tag) on the commit origin/main is at, and pushed. MELPA Stable builds its
# package from that tag (melpa.org builds every commit). Checked first, in
# order, nothing tagged if one fails:
#
# - the version: X.Y.Z, agent-ui.el's (VERSION given: the same, so a
#   mistyped one stops it), its tag taken neither here nor on origin;
# - main checked out, nothing changed or untracked, at origin/main's commit
#   (fetched): what's tagged is what was pushed, what CI ran on;
# - CI on that commit: each of the repository's workflows (Tests, melpazoid)
#   finished and passed;
# - each package in its Package-Requires on MELPA Stable, at its version at
#   least: its users install from there.
#
# Then it asks before tagging and pushing (--yes: it doesn't).
#
#   scripts/release.sh              the header's version
#   scripts/release.sh 0.1.0        the same, said
#   scripts/release.sh --dry-run    the checks only, nothing tagged
#
# Needs git, gh (signed in: CI's runs), curl, and emacs (the header read,
# the versions compared). RELEASE_BRANCH (default: main) is the branch.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRANCH=${RELEASE_BRANCH:-main}
MAIN_FILE=agent-ui.el
STABLE=https://stable.melpa.org/packages/archive-contents

dry_run=
yes=
given=
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --yes|-y) yes=1 ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "release: unknown option $arg (see --help)" >&2; exit 2 ;;
    *) [ -z "$given" ] || { echo "release: one version at most" >&2; exit 2; }
       given=$arg ;;
  esac
done

fail() { printf '  ✗ %s\n\nrelease: nothing tagged.\n' "$*" >&2; exit 1; }
ok() { printf '  ✓ %s\n' "$*"; }

cd "$ROOT"
for tool in git gh curl emacs; do
  command -v "$tool" >/dev/null || fail "$tool isn't installed"
done

echo "The version"
version=$(sed -n 's/^;; Version: *//p' "$MAIN_FILE" | head -1)
[ -n "$version" ] || fail "$MAIN_FILE has no ;; Version: header"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "$MAIN_FILE's version, $version, isn't X.Y.Z"
if [ -n "$given" ] && [ "${given#v}" != "$version" ]; then
  fail "$MAIN_FILE says $version, not ${given#v}: change its ;; Version: header first (committed, pushed)"
fi
tag="v$version"
ok "$version, $MAIN_FILE's"

echo "The commit"
current=$(git symbolic-ref --quiet --short HEAD || echo "a detached HEAD")
[ "$current" = "$BRANCH" ] || fail "$current checked out, not $BRANCH"
[ -z "$(git status --porcelain)" ] || fail "changes not committed (git status)"
git fetch --quiet --tags origin "$BRANCH" || fail "origin couldn't be fetched"
head=$(git rev-parse HEAD)
remote=$(git rev-parse "origin/$BRANCH")
if [ "$head" != "$remote" ]; then
  if git merge-base --is-ancestor "$remote" "$head"; then
    fail "commits not pushed: $(git rev-list --count "$remote..$head") ahead of origin/$BRANCH (git push)"
  else
    fail "origin/$BRANCH has commits not here (git pull)"
  fi
fi
ok "$(git log -1 --format='%h %s' "$head"), as on origin/$BRANCH"
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
  fail "$tag is taken here already, on $(git log -1 --format=%h "$tag")"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "$tag is taken on origin already"
fi
ok "$tag not taken, here nor on origin"

echo "CI on it"
workflows=$(gh workflow list --json name,state --jq '.[] | select(.state == "active") | .name') \
  || fail "gh couldn't list the workflows (gh auth status)"
[ -n "$workflows" ] || fail "no workflow is active"
while IFS= read -r workflow; do
  run=$(gh run list --workflow "$workflow" --commit "$head" --limit 1 \
          --json status,conclusion,url --jq '.[0] // empty | "\(.status) \(.conclusion) \(.url)"')
  [ -n "$run" ] || fail "$workflow: no run on this commit"
  read -r status conclusion url <<<"$run"
  [ "$status" = completed ] || fail "$workflow: still running ($url)"
  [ "$conclusion" = success ] || fail "$workflow: $conclusion ($url)"
  ok "$workflow passed"
done <<<"$workflows"

echo "Its dependencies on MELPA Stable"
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -fsSL --max-time 120 "$STABLE" -o "$archive" || fail "MELPA Stable's archive couldn't be fetched"
ARCHIVE="$archive" MAIN_FILE="$MAIN_FILE" emacs -Q --batch --eval '
(progn
  (require (quote lisp-mnt))
  (require (quote package))
  (let* ((archive (with-temp-buffer
                    (insert-file-contents (getenv "ARCHIVE"))
                    (cdr (read (current-buffer)))))
         (requires (with-temp-buffer
                     (insert-file-contents (getenv "MAIN_FILE"))
                     (car (read-from-string (or (lm-header "Package-Requires") "()")))))
         (missing 0))
    (dolist (require requires)
      (unless (eq (car require) (quote emacs))
        (let* ((entry (cdr (assq (car require) archive)))
               (has (and entry (aref entry 0)))
               (needs (version-to-list (cadr require))))
          (if (and has (version-list-<= needs has))
              (princ (format "  ✓ %s %s (%s needed)\n" (car require) (package-version-join has) (cadr require)))
            (setq missing (1+ missing))
            (princ (format "  ✗ %s %s needed, MELPA Stable has %s\n" (car require) (cadr require)
                           (if has (package-version-join has) "none")))))))
    (kill-emacs (if (zerop missing) 0 1))))' \
  || fail "a dependency isn't on MELPA Stable at the version needed: its users couldn't install it"

echo
if [ -n "$dry_run" ]; then
  echo "Ready: $tag on $(git log -1 --format=%h "$head") (--dry-run: nothing tagged)."
  exit 0
fi
if [ -z "$yes" ]; then
  answer=
  read -r -p "Tag $tag on $(git log -1 --format=%h "$head") and push it to origin? [y/N] " answer || true
  case "$answer" in
    y|Y|yes) ;;
    *) echo "release: nothing tagged."; exit 1 ;;
  esac
fi
git tag -a "$tag" -m "Agent UI $version" "$head"
if ! git push --quiet origin "refs/tags/$tag"; then
  git tag -d "$tag" >/dev/null
  echo "release: the push failed; the tag is deleted here too." >&2
  exit 1
fi
echo "$tag pushed: $(git ls-remote --tags origin "refs/tags/$tag" | cut -c1-12)."
echo "MELPA Stable builds it once the recipe is in melpa/melpa. Next: a new"
echo "version in $MAIN_FILE's ;; Version: header before the next release."
