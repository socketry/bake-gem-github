# Releases

## Unreleased

  - Stop generating `.github/releasing.md`; release instructions are maintained in the shared guide and agent context.
  - Resume interrupted release preparation and explicitly refresh stale release PRs while preserving their previous commits.
  - Preserve all release files in one archive before individual asset uploads, so reruns can recover interrupted drafts.

## v0.2.0

  - Use only the version tag for GitHub release titles.

## v0.1.0

  - Include the version's release notes in GitHub releases using `bake-releases`.
  - Update generated release files in the working tree with `gem:github:setup:update`.

## v0.0.5

  - Preserve and recover release files even when GitHub's release list is stale.

## v0.0.4

  - Preserve verified release files in a draft GitHub release before uploading to RubyGems, so reruns can recover when Actions artifacts disappear.
  - Wait for RubyGems registry propagation before finalizing releases.

## v0.0.1

  - Initial implementation.
