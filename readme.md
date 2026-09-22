# Bake::Gem::GitHub

Reviewed GitHub releases for Ruby gems, using `bake-gem` for branch preparation, independent content validation, and clean builds.

- `gem:github:release:patch` / `minor` / `major`: prepare, push and open a release PR.
- `gem:github:setup`: generate the three workflows and native review/CI policy.
- `gem:github:setup:plan` / `apply`: inspect and apply the managed GitHub rulesets.
- `gem:github:release:resume run=ID`: retry with the original artifact.

Read [the setup, release and recovery guide](https://github.com/socketry/bake-gem-github/blob/main/guides/getting-started/readme.md) before enabling publishing. Context is distributed through `agent-context`. This initial implementation requires `bake-gem` 0.15 or later and a live pilot before wider rollout.

## Making Releases

To prepare a release branch and open a pull request from an up-to-date `main`:

``` bash
$ bundle exec bake gem:github:release:patch # or minor or major
```

See [bake-gem-github](https://github.com/socketry/bake-gem-github) for setup, remote releases, and recovery.

## Development

Run `bundle exec bake test` for the test suite and `bundle exec rubocop` for style checks. The test, coverage, documentation, and RuboCop workflows follow `bake modernize` conventions.

Install maintenance dependencies with `BUNDLE_WITH=maintenance bundle install`, then run `BUNDLE_WITH=maintenance bundle exec bake agent:context:install` for local agent guidance. Generated `agents.md` and `.agents/context/` files are ignored.

Review modernization changes before committing them. Retain the Socketry certificate, the `~/.gem/socketry-release.pem` signing key path, and packaged release templates. Publishing is handled by `release-publish.yaml`; do not add a second publishing hook to `bake.rb`.
