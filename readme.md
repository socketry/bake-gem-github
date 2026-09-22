# Bake::Gem::GitHub

Reviewed GitHub releases for Ruby gems, using `bake-gem` for branch preparation, independent content validation, and clean builds.

[![Development Status](https://github.com/socketry/bake-gem-github/workflows/Test/badge.svg)](https://github.com/socketry/bake-gem-github/actions?workflow=Test)

## Motivation

Maintainers need a shared release process that they can run locally or through GitHub. This gem prepares release pull requests for review, validates their generated content, and publishes the merged release through GitHub Actions using RubyGems Trusted Publishing. Retained artifacts and attestations allow interrupted releases to resume using the original verified bytes.

## Usage

Please see the [project documentation](https://socketry.github.io/bake-gem-github/) for more details.

  - [Getting Started](https://socketry.github.io/bake-gem-github/guides/getting-started/index) - This guide explains how to configure reviewed Ruby gem releases and prepare the first release PR with `bake-gem-github`.

  - [Preparing Releases](https://socketry.github.io/bake-gem-github/guides/preparing-releases/index) - This guide explains how to request a release PR, resume interrupted preparation, and refresh generated content when the default branch changes.

  - [Verifying Releases](https://socketry.github.io/bake-gem-github/guides/verifying-releases/index) - This guide explains how publishing binds a gem to its reviewed source and how to verify the downloaded artifact and attestations.

  - [Recovering Releases](https://socketry.github.io/bake-gem-github/guides/recovering-releases/index) - This guide explains how to resume an interrupted publishing workflow using the original gem and its verification evidence.

## Releases

Please see the [project releases](https://socketry.github.io/bake-gem-github/releases/index) for all releases.

### v0.3.0

  - Configure publishing environment reviewers through release setup while preserving existing environment protections.
  - Stop generating `.github/releasing.md`; release instructions are maintained in the shared guide and agent context.
  - Resume interrupted release preparation and explicitly refresh stale release PRs while preserving their previous commits.
  - Preserve all release files in one archive before individual asset uploads, so reruns can recover interrupted drafts.

### v0.2.0

  - Use only the version tag for GitHub release titles.

### v0.1.0

  - Include the version's release notes in GitHub releases using `bake-releases`.
  - Update generated release files in the working tree with `gem:github:setup:update`.

### v0.0.5

  - Preserve and recover release files even when GitHub's release list is stale.

### v0.0.4

  - Preserve verified release files in a draft GitHub release before uploading to RubyGems, so reruns can recover when Actions artifacts disappear.
  - Wait for RubyGems registry propagation before finalizing releases.

### v0.0.1

  - Initial implementation.

## Contributing

We welcome contributions to this project.

1.  Fork the repository.
2.  Create your feature branch (`git checkout -b my-new-feature`).
3.  Commit your changes (`git commit -am 'Add some feature.'`).
4.  Push to the branch (`git push origin my-new-feature`).
5.  Create a new pull request.

### Running Tests

To run the test suite:

``` bash
$ bundle exec sus
```

### Making Releases

To prepare a release branch and open a pull request from an up-to-date `main`:

``` bash
$ bundle exec bake gem:github:release:patch # or minor or major
```

See [bake-gem-github](https://github.com/socketry/bake-gem-github) for setup, remote releases, and recovery.

### Developer Certificate of Origin

In order to protect users of this project, we require all contributors to comply with the [Developer Certificate of Origin](https://developercertificate.org/). This ensures that all contributions are properly licensed and attributed.

### Community Guidelines

This project is best served by a collaborative and respectful environment. Treat each other professionally, respect differing viewpoints, and engage constructively. Harassment, discrimination, or harmful behavior is not tolerated. Communicate clearly, listen actively, and support one another. If any issues arise, please inform the project maintainers.
