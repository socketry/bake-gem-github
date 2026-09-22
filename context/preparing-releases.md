# Preparing Releases

This guide explains how to request a release PR, resume interrupted preparation, and refresh generated content when the default branch changes.

Complete [Getting Started](../getting-started/index) first. Release preparation uses {ruby Bake::Gem::GitHub::Project#prepare} to coordinate the core Bake tasks and GitHub operations. Run local tasks from the repository root so gemspec paths resolve correctly.

## Request a release

``` bash
# Local branch and commit only:
bundle exec bake gem:release:branch:patch

# From the current default branch: prepare, validate, push and open PR:
bundle exec bake gem:github:release:patch

# Remote request (also available in the Actions UI):
gh workflow run release-prepare.yaml -f bump=patch
```

Replace `patch` with `minor` or `major`. The wrapper fetches the default branch and tags, refuses a stale local checkout, and validates an existing release PR before returning its URL. A matching local or remote branch is reused if PR creation was interrupted. Multiple open release PRs or a different requested bump stop preparation. GitHub's built-in token may require a writer to approve running workflows for its created PR; enable Actions' permission to create PRs. An organization-owned App token can be adopted later if automatic CI triggering is needed.

All release changes belong in the PR. Core preparation commits additions and deletions from release hooks but never pushes, tags or publishes. Validation independently generates the expected tree from the current base. A changed base SHA alone is fine; changed generated notes are not. Ordinary PRs with no version change pass release validation and still build unsigned.

## Resume interrupted preparation

If preparation stops after creating or pushing the release branch, return to the current default branch and repeat the same command. The existing branch is validated and reused, so retries do not create a second version bump or PR. Resolve any uncommitted changes before switching branches.

## Refresh stale content

When new changes alter the generated release notes or other artifacts, rebasing the branch alone does not regenerate them. Validation reports the stale content. Explicitly refresh the same release:

``` bash
git switch main
git pull --ff-only
bundle exec bake gem:github:release:patch refresh=true
# Or dispatch remotely:
gh workflow run release-prepare.yaml -f bump=patch -f refresh=true
```

Refresh first pushes the complete previous release commit to `release-backups/vVERSION/OLD_SHA`, including manual edits. It then regenerates in a clean worktree from the current default branch, validates, and updates the existing release branch using an explicit `--force-with-lease`. A concurrent remote edit causes the push to fail. Existing local release branches are left intact. Review the backup against the refreshed PR; incorporate necessary manual changes into the default branch or generation hooks and refresh again. Keep the backup until that review is complete. Replace `main` and `patch` with your configured branch and original bump type.
