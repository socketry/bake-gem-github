# Verifying Releases

This guide explains how publishing binds a gem to its reviewed source and how to verify the downloaded artifact and attestations.

Use this when checking a completed release or confirming which source commit produced a package. [Getting Started](../getting-started/index) describes publisher configuration; [Recovering Releases](../recovering-releases/index) covers interrupted workflows.

## What publishing verifies

After squash, rebase, or merge, the publishing workflow verifies GitHub's merged PR record and ancestry, then checks out the exact resulting commit. Each release PR contains one commit, so the resulting commit's **first parent** is the default branch immediately before the release landed. Later development on the default branch is allowed. Publishing regenerates against that first parent, builds in a clean worktree, optionally certificate-signs, and creates two attestations over the final bytes:

- A Sigstore bundle submitted explicitly with `gem push --attestation` using RubyGems 4.0.21.
- GitHub's native SLSA provenance covering both the gem and `release.json`. This signed receipt binds the gem digest to the exact release commit, even when the workflow's own default-branch revision is newer.

The workflow retains the gem, receipt and attestations before obtaining RubyGems publishing credentials. It verifies both attestations, checks the uploaded bytes and registry bundle, then pushes the specific version tag and creates the GitHub release. Existing tags/assets are checked and never overwritten. The old `after_gem_release` GitHub hook is not called by this pipeline, so there is one owner for release creation.

The draft release description includes the exact version's notes from `releases.md` in the merged release checkout, followed by the PR URL, source commit, and gem digest. Notes are extracted using `bake-releases`; a missing or empty section leaves the metadata as the description. Retries preserve the existing release description.

## Verify downloaded artifacts

Download the gem, its `.sigstore.json` bundle, `release.json`, and `provenance.sigstore.json` from the GitHub release. Replace the example package, owner/repository, and `MERGED_SHA` below with the release being checked. Run from the directory containing those files:

``` bash
set -e
for file in example-1.2.3.gem release.json; do
  gh attestation verify "$file" \
    --repo OWNER/REPOSITORY --bundle provenance.sigstore.json \
    --cert-identity https://github.com/OWNER/REPOSITORY/.github/workflows/release-publish.yaml@refs/heads/main \
    --source-ref refs/heads/main --deny-self-hosted-runners
done

jq -e --arg commit MERGED_SHA \
  --arg digest "$(shasum -a 256 example-1.2.3.gem | cut -d ' ' -f1)" \
  '.commit == $commit and .sha256 == $digest' release.json

gem exec sigstore-cli:0.2.3 verify example-1.2.3.gem \
  --bundle example-1.2.3.gem.sigstore.json \
  --certificate-identity https://github.com/OWNER/REPOSITORY/.github/workflows/release-publish.yaml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Download `release.json` and `provenance.sigstore.json` alongside the gem. Verify both subjects before reading the receipt's source commit and digest. GitHub CLI's `--source-digest` checks the workflow revision, which may differ from the release commit recorded in the signed receipt. Replace `main` with the configured default branch in these commands.

Native GitHub records the merge and any bypass; the signed artifact receipt includes the PR and merging actor. This version does not export organization audit-log evidence or infer bypass reasons from review counts.
