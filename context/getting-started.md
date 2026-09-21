# GitHub Releases

This guide sets up reviewed Ruby gem releases with `bake-gem-github`, native GitHub rules, RubyGems Trusted Publishing, and retained release artifacts.

## Installation

Add `bake-gem-github` and `agent-context` to your maintenance bundle. This companion requires `bake-gem` 0.15 or later for branch preparation and regeneration validation. Install the maintenance group in CI with `BUNDLE_WITH=maintenance`.

Use one gemspec, a stable three-part version in `lib/.../version.rb`, and repeatable `after_gem_release_version_increment` hooks. Hooks run from a clean base during validation. Commit dependency locks when practical; changing generation tools or using live network/time inputs can make old release content fail validation.

## Setup and migration

Run setup in each repository. It discovers the canonical repository and default branch through `gh` and generates reviewable local files. Supply the actual required CI job names, including supported matrix entries:

``` bash
bundle exec bake gem:github:setup checks="Test Ruby 3.3,Test Ruby 3.4,RuboCop"
bundle exec bake agent:context:install
bundle exec bake gem:github:setup:plan
```

Setup adds three release workflows, `config/release.yaml`, native ruleset payloads, and `.github/releasing.md`. Identical reruns do nothing; conflicting existing files stop before any file is written. Setup does not replace other publishers: remove conflicting release workflows during migration.

To adopt template fixes after upgrading the gem, start from a clean working tree, edit `config/release.yaml` as needed, and regenerate:

``` bash
bundle exec bake gem:github:setup:update
git diff
```

The task updates the managed workflows, policy payloads, configuration formatting, and maintainer instructions directly in the working tree and returns the changed paths. It does not stage, commit, or change remote settings. An agent or maintainer can review the diff and selectively keep changes, restoring repository-specific customizations from Git where needed. Commit or stash existing edits first: generated files are replaced by the current templates. Repeating an update produces no further changes; intentionally retained customizations will appear in later update diffs. Apply remote rulesets after the corresponding workflows are running.

Release workflows follow `bake modernize` action versions and use moving major tags where upstream provides them. These tags receive upstream updates automatically; full commit hashes select fixed revisions. The RubyGems credentials action uses its [documented `@main` reference](https://github.com/rubygems/configure-rubygems-credentials#trusted-publisher-recommended), since upstream does not provide a moving major tag. Repositories that require fixed revisions can customize these references.

The default is two approvals with explicit administrator bypass, dismissed stale reviews, approval of the last push, strict up-to-date CI, and immutable default-branch history/release tags. These branch rules affect **all PRs** into the default branch. Ordinary administrator reviews count as one review. A human who dispatches a bot-authored PR is not its author under GitHub's native rules.

Review `gem:github:setup:plan`, merge the setup PR, and confirm that **Release validation** and every selected check run. Then apply the four managed rulesets using an administrator's `gh` login:

``` bash
bundle exec bake gem:github:setup:apply
```

This command changes remote rulesets and preserves unrelated rulesets. Existing rulesets with the four managed names are updated. Organization rules and other existing protections still apply. Check names in configuration must exactly match GitHub checks; a partial selection does not mean all CI is required. Keep rebase merging and merge queues disabled for the initial rollout.

Create a `rubygems` GitHub environment restricted to the default branch. Do not add a second routine reviewer gate. On RubyGems, an owner must configure a Trusted Publisher with the owner/repository, workflow filename **`release-publish.yaml`**, and environment **`rubygems`** shown by `doctor`. Ownership/MFA and environment/signing bootstrap are deliberate manual steps in this first implementation; `doctor` prints desired and observed GitHub settings, not a claim that RubyGems ownership or publisher trust has been verified. See [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).

If `release.cert` exists, setup enables legacy signing. Keep this public certificate in Git and install its matching **private key** as the Actions secret `GEM_SIGNING_KEY`. Use the `rubygems` environment or an organization secret available to the release repositories. The workflow checks the certificate validity, key match, and resulting package signatures. To opt out explicitly, pass `signing=false` during setup. No long-lived RubyGems publishing key is required.

Before enabling releases, confirm two people can administer the repository and recover the RubyGems account/signing key, and enough maintainers can satisfy the review policy. Pilot on one low-risk gem and prove publishing, administrator bypass, fork merges, and recovery before rolling out broadly. No organization-wide migration or live publisher setup is performed by these tasks.

## Request and review

``` bash
# Local branch and commit only:
bundle exec bake gem:release:branch:patch

# From the current default branch: prepare, validate, push and open PR:
bundle exec bake gem:github:release:patch

# Remote request (also available in the Actions UI):
gh workflow run release-prepare.yaml -f bump=patch
```

Replace `patch` with `minor` or `major`. The wrapper fetches the default branch and tags, refuses a stale local checkout, and reports an existing release PR instead of opening another. GitHub's built-in token may require a writer to approve running workflows for its created PR; enable Actions' permission to create PRs. An organization-owned App token can be adopted later if automatic CI triggering is needed.

All release changes belong in the PR. Core preparation commits additions and deletions from release hooks but never pushes, tags or publishes. Validation independently generates the expected tree from the current base. A changed base SHA alone is fine; changed generated notes are not. Ordinary PRs with no version change pass release validation and still build unsigned.

If regeneration fails, prepare a new branch from the current default branch and review the new diff. Preserve manual release-branch edits separately. Automatic refresh/force-push is not implemented. A failure during preparation leaves the branch and generated changes available for inspection.

## Publish and verify

After merge/squash, the publishing workflow verifies GitHub's merged PR record and ancestry, then checks out the exact merged commit. Later development on the default branch is allowed. It regenerates against the merged commit's **first parent**, builds in a clean worktree, optionally certificate-signs, and creates two attestations over the final bytes:

- A Sigstore bundle submitted explicitly with `gem push --attestation` using RubyGems 4.0.21.
- GitHub's native SLSA provenance covering both the gem and `release.json`. This signed receipt binds the gem digest to the exact release commit, even when the workflow's own default-branch revision is newer.

The workflow retains the gem, receipt and attestations before obtaining RubyGems publishing credentials. It verifies both attestations, checks the uploaded bytes and registry bundle, then pushes the specific version tag and creates the GitHub release. Existing tags/assets are checked and never overwritten. The old `after_gem_release` GitHub hook is not called by this pipeline, so there is one owner for release creation.

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

## Recovery

Use **Re-run all jobs** on the original publishing run, or:

``` bash
bundle exec bake gem:github:release:resume run=RUN_ID
```

Rerunning keeps the original event identity. A retained artifact is downloaded and its source identity/digest checked. A matching registry version resumes tag/release finalization; different bytes or a conflicting tag stop. There is no automatic yank, retag, or rebuild of an already-published version. Registry propagation is retried every ten seconds for up to one minute; a digest or attestation mismatch fails immediately.

Before uploading to RubyGems, the publisher stores the verified gem, receipt and both attestation bundles in a draft GitHub release targeting the merged commit. It publishes the draft after registry verification and tag creation. Actions artifacts are also retained for 90 days, but can disappear on rerun. Recovery falls back to the draft or published release and verifies the original bytes and attestations. Keep the draft until finalization succeeds. If asset preservation was interrupted and neither backup is complete, restore the missing original files before retrying; conflicting assets are never overwritten.

GitHub concurrency does not guarantee a durable FIFO queue: rerun any publishing run displaced while pending. Resume reruns all jobs, including integrity checks; it does not repeat or second-guess the native review policy or a permitted administrator bypass. Older publishing runs execute their original code; adding this recovery support to the default branch does not change an already-triggered workflow.

## Development and current limits

The implementation has local repository and transport-fake tests. A real GitHub/RubyGems pilot remains necessary before enabling it across Socketry. Public single-gem repositories, ordinary stable versions, merge/squash, GitHub-hosted Linux runners, and RubyGems.org are the supported starting point. Native build matrices, reusable publisher workflows, merge queues, automated RubyGems ownership/MFA setup, cross-run artifact recovery, and organization-wide rollout are deferred.

Edit this guide and regenerate `context/` with `bake utopia:project:agent:context:update`. Consumers install the generated guidance using `agent-context`.
