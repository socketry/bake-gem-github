# Getting Started

This guide explains how to configure reviewed Ruby gem releases and prepare the first release PR with `bake-gem-github`.

## How releases work

Maintainers prepare a release PR containing the version bump and generated release notes. CI regenerates those changes from the current base to verify the content. Native GitHub rules control approval and merging; after merge, GitHub Actions builds the exact merged commit and publishes its verified artifact to RubyGems.

`bake-gem` provides version updates, release hooks, and clean builds. `bake-gem-github` adds PR preparation, GitHub policy, and remote publishing. The supported process uses one gemspec, stable three-part versions, merge or squash merging, and RubyGems.org.

## Installation

Add these dependencies to the maintenance group in `gems.rb`:

``` ruby
group :maintenance, optional: true do
	gem "bake-gem-github"
	gem "agent-context"
end
```

Install that group and its guidance:

``` bash
bundle config set --local with maintenance
bundle install
bundle exec bake agent:context:install
```

The companion requires `bake-gem` 0.15 or later. Its generated release workflows install maintenance dependencies with `BUNDLE_WITH=maintenance`.

Use a version constant in `lib/.../version.rb` and repeatable `after_gem_release_version_increment` hooks. Validation invokes these hooks from a clean base. Generation must not depend on changing network responses or the current time; review dependency updates that could alter generated content.

## Generate repository configuration

Run setup from the repository root with the actual required CI job names, including supported matrix entries:

``` bash
bundle exec bake gem:github:setup checks="3.3 on ubuntu,3.3 on macos,3.4 on ubuntu,3.4 on macos,4.0 on ubuntu,4.0 on macos,check,ruby on ubuntu,ruby on macos,validate"
bundle exec bake gem:github:setup:plan
```

This example follows the standard `bake modernize` test, RuboCop, and coverage job names. Select the jobs produced by your repository. Experimental Ruby jobs are not required. Setup adds `Release validation` automatically.

Setup discovers the canonical GitHub repository and default branch through `gh`. It generates three release workflows, `config/release.yaml`, and four native ruleset payloads. Identical reruns do nothing; conflicting existing files stop generation before any file is written. Review and commit the files in a setup PR, and remove conflicting publishing workflows.

The rules require two approvals by default, allow explicit administrator bypass, dismiss stale reviews, require approval of the last push, and require up-to-date CI. They protect default-branch history and release tags against deletion or replacement. These branch rules apply to **all PRs** into the default branch. An ordinary administrator approval counts as one review; bypass is a separate action.

## Configure publishing credentials

Create a `rubygems` GitHub environment restricted to the default branch. On RubyGems, an owner must configure a Trusted Publisher with the values printed by `gem:github:setup:plan`: the owner/repository, workflow filename **`release-publish.yaml`**, and environment **`rubygems`**. See [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) for the account setup.

Ownership, MFA, and signing bootstrap are manual setup steps. The plan reports expected RubyGems values; it does not verify ownership or publisher trust. Trusted Publishing supplies the publishing credential for each run, so a long-lived RubyGems API key is unnecessary.

When `release.cert` exists, setup enables certificate signing. Commit the public certificate and install its matching private key as `GEM_SIGNING_KEY`, either in the `rubygems` environment or as an organization secret available to the repository. The publisher checks certificate validity, key matching, and package signatures. Use `signing=false` during setup to disable certificate signing.

Ensure another maintainer can administer the repository and recover its RubyGems account and signing key. Keep the native PR review policy as the routine approval step; the environment does not need another reviewer gate.

## Enable the policy

Merge the setup PR and confirm every selected CI job, including **Release validation**, runs. Review the plan again, then apply its rules using an administrator's `gh` login:

``` bash
bundle exec bake gem:github:setup:plan
bundle exec bake gem:github:setup:apply
```

Apply updates only the four managed rulesets and preserves unrelated rulesets. Other repository and organization protections still apply. Keep check names in `config/release.yaml` synchronized with the workflows, and apply updated rules after renamed jobs are available. Keep rebase merging and merge queues disabled for this process.

## Prepare the first release PR

From an up-to-date default branch:

``` bash
bundle exec bake gem:github:release:patch
```

The task prepares, validates, pushes, and opens the release PR. Review its version and release notes, wait for CI, and merge under the repository's approval policy. The publish workflow builds the merged release, verifies and preserves the artifact, publishes to RubyGems, and finalizes the version tag and GitHub release.

See [Preparing Releases](../preparing-releases/index) for remote requests and stale-content refresh, [Verifying Releases](../verifying-releases/index) for artifact checks, and [Recovering Releases](../recovering-releases/index) when a workflow stops partway through.

## Update generated files

After upgrading the gem, start from a clean working tree and regenerate using your existing configuration:

``` bash
bundle exec bake gem:github:setup:update
git diff
```

This updates managed files in the working tree and returns their changed paths. Review the diff and selectively retain repository customizations before committing. The task does not stage, commit, or change remote settings. Repeated updates produce no further changes unless customizations differ from the templates. Apply changed rulesets after the corresponding workflows are running.

The release workflows follow `bake modernize` action versions and use moving major tags where available. The RubyGems credentials action uses its [documented `@main` reference](https://github.com/rubygems/configure-rubygems-credentials#trusted-publisher-recommended). Repositories that require fixed revisions can customize these references.

## Current scope

The process has published `bake-gem-github` through GitHub Actions. Each adopting repository still needs its own reviewed setup and successful release. Public single-gem repositories, ordinary stable versions, merge/squash, GitHub-hosted Linux runners, and RubyGems.org are the supported starting point.

Native build matrices, reusable publisher workflows, merge queues, automated RubyGems ownership/MFA setup, cross-run artifact recovery, and organization-wide migration are outside the current setup tasks.

Edit source guides under `guides/` and regenerate the distributed guidance with `bundle exec bake utopia:project:agent:context:update`. Consumers install it through `agent-context`.
