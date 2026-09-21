# Bake::Gem::GitHub

Reviewed GitHub releases for Ruby gems, using `bake-gem` for branch preparation, independent content validation, and clean builds.

- `gem:github:release:patch` / `minor` / `major`: prepare, push and open a release PR.
- `gem:github:setup`: generate the three workflows and native review/CI policy.
- `gem:github:setup:plan` / `apply`: inspect and apply the managed GitHub rulesets.
- `gem:github:release:resume run=ID`: retry with the original artifact.

Read [the setup, release and recovery guide](guides/getting-started/readme.md) before enabling publishing. Context is distributed through `agent-context`. This initial implementation requires `bake-gem` 0.15 or later and a live pilot before wider rollout.

## Making Releases

To prepare a release branch and open a pull request from an up-to-date `main`:

``` bash
$ bundle exec bake gem:github:release:patch # or minor or major
```

See [bake-gem-github](https://github.com/socketry/bake-gem-github) for setup, remote releases, and recovery.
