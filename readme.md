# Bake::Gem::GitHub

Reviewed GitHub releases for Ruby gems, using `bake-gem` for branch preparation, independent content validation, and clean builds.

[![Development Status](https://github.com/socketry/bake-gem-github/workflows/Test/badge.svg)](https://github.com/socketry/bake-gem-github/actions?workflow=Test)

## Motivation

Maintainers need a shared release process that they can run locally or through GitHub. This gem prepares release pull requests for review, validates their generated content, and publishes the merged release through GitHub Actions using RubyGems Trusted Publishing. Retained artifacts and attestations allow interrupted releases to resume using the original verified bytes.

## Usage

Please see the [project documentation](https://socketry.github.io/bake-gem-github/) or run it locally using `bake utopia:project:serve`.

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
