#!/bin/bash
source "$(dirname "$0")/common.sh"

usage() {
    printf 'Usage: bash scripts/release.sh VERSION [--draft] [--dry-run] [--notes-file PATH]\n'
    printf 'Build, sign, tag the current commit, and publish a GitHub release. Never creates commits.\n'
}
[[ "${1:-}" != --help && $# -gt 0 ]] || { usage; exit 0; }
version="$(app_version "$1")"
shift
draft=false
dry_run=false
notes=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --draft) draft=true; shift ;;
        --dry-run) dry_run=true; shift ;;
        --notes-file)
            [[ $# -ge 2 && -f "$2" ]] || fail '--notes-file requires an existing Markdown file.'
            notes="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
            shift 2 ;;
        *) usage; fail "Unknown option: $1" ;;
    esac
done
command -v gh >/dev/null || fail 'Install GitHub CLI (brew install gh), then run gh auth login.'
commit="$(git rev-parse --verify HEAD 2>/dev/null)" || fail 'Create your first Git commit before releasing.'
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail 'Commit or stash your changes before releasing (including untracked source files).'
remote="$(git remote get-url origin)"
remote_repo="$(python3 scripts/release-tools.py remote-repository "$remote")"
[[ "$(printf '%s' "$remote_repo" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$RELEASE_REPO" | tr '[:upper:]' '[:lower:]')" ]] ||
    fail "origin must point to $RELEASE_REPO. Set RELEASE_REPO explicitly when releasing a fork."
gh auth status --hostname github.com >/dev/null 2>&1 || fail 'Run gh auth login before releasing.'
tag="v$version"
if git show-ref --verify --quiet "refs/tags/$tag"; then
    [[ "$(git rev-list -n 1 "$tag")" == "$commit" ]] || fail "$tag already points to another commit."
fi
remote_tags="$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")"
remote_commit="$(printf '%s\n' "$remote_tags" | awk 'NF {value=$1} END {print value}')"
[[ -z "$remote_commit" || "$remote_commit" == "$commit" ]] || fail "Remote $tag already points to another commit."
draft_id="$(gh api "repos/$RELEASE_REPO/releases" --paginate --slurp | python3 scripts/release-tools.py preflight "$version")"
if $dry_run; then
    printf 'Ready: test and package %s from commit %s, push only tag %s, upload verified assets, %s.\n' \
        "$version" "$commit" "$tag" "$(if $draft; then printf 'keep draft'; else printf 'publish as latest'; fi)"
    exit 0
fi
export APP_VERSION="$version"
if [[ -n "$notes" ]]; then export RELEASE_NOTES_FILE="$notes"; fi
make test
bash scripts/package.sh "$version"
make test-updater
# A long build must never tag a different commit or include concurrent source edits.
[[ "$(git rev-parse HEAD)" == "$commit" && -z "$(git status --porcelain --untracked-files=normal)" ]] ||
    fail 'Source changed during packaging. Nothing has been tagged or uploaded.'
directory="$PROJECT_ROOT/build/releases/$tag"
if ! git show-ref --verify --quiet "refs/tags/$tag"; then
    git tag -a "$tag" "$commit" -m "Dell PBP $version"
fi
if [[ -z "$remote_commit" ]]; then git push origin "refs/tags/$tag"; fi
# Failures after this point leave a recoverable tag/draft. Rerun the same command
# from the same commit. Published releases are never overwritten.
trap 'printf "Release incomplete. Tag/draft retained; rerun this command from the same commit.\n" >&2' ERR
notes_args=(--generate-notes)
if [[ -n "$notes" ]]; then notes_args=(--notes-file "$notes"); fi
if [[ -z "$draft_id" ]]; then
    gh release create "$tag" --repo "$RELEASE_REPO" --verify-tag --draft \
        --title "Dell PBP $version" "${notes_args[@]}"
else
    if [[ -n "$notes" ]]; then gh release edit "$tag" --repo "$RELEASE_REPO" --notes-file "$notes"; fi
fi
[[ "$(gh release view "$tag" --repo "$RELEASE_REPO" --json isDraft --jq .isDraft)" == true ]] ||
    fail 'Release is no longer a draft. Refusing to replace published assets.'
gh release upload "$tag" --repo "$RELEASE_REPO" --clobber \
    "$directory/$ARCHIVE_NAME" "$directory/appcast.xml" "$directory/SHA256SUMS"
release_id="$(gh release view "$tag" --repo "$RELEASE_REPO" --json databaseId --jq .databaseId)"
gh api "repos/$RELEASE_REPO/releases/$release_id" | python3 scripts/release-tools.py assets "$directory"
if $draft; then
    printf 'Verified draft: https://github.com/%s/releases/tag/%s\n' "$RELEASE_REPO" "$tag"
else
    # Another release may have been published during the build/upload.
    gh api "repos/$RELEASE_REPO/releases" --paginate --slurp | python3 scripts/release-tools.py preflight "$version" >/dev/null
    gh release edit "$tag" --repo "$RELEASE_REPO" --draft=false --latest
    printf 'Published: https://github.com/%s/releases/tag/%s\n' "$RELEASE_REPO" "$tag"
fi
