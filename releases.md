# Releases

## v0.5.0

  - Support rebase merging by requiring each release PR to contain exactly one commit, while leaving ordinary PRs unrestricted. Generated rules allow merge, squash, and rebase methods according to repository settings.

## v0.4.0

  - Reject Secret environment reviewer teams before applying release settings, and verify that GitHub retained the requested reviewers and existing protections after updating the environment.

## v0.3.1

  - Publish validated release PRs from pushes to the default branch, retaining the exact merged commit and environment approval without requiring `pull_request_target`.
  - Queue publishing jobs without replacing pending releases when later changes land.

## v0.3.0

  - Configure publishing environment reviewers through release setup while preserving existing environment protections.
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
