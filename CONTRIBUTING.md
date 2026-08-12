# Contributing

Install dependencies and run the complete local gate:

```sh
bundle install
bundle exec rake
```

When jq 1.7.1 is available, also run the independent byte-level comparison:

```sh
JQ_BIN=/path/to/jq-1.7.1 bundle exec rake differential
```

Build and smoke-test the gem before changing packaging:

```sh
gem build rjq.gemspec
gem install ./rjq-*.gem
rjq -nc '{installed: true}'
```

Changes to semantics should include a focused regression test and, where jq behavior is the contract, a differential case. Avoid deriving both expected and actual values through the same parser or comparator. Preserve partial output and verify the terminal error/status separately.

The bundled jq fixtures are adapted regression inputs. If they change, update `spec/fixtures/jq/manifest.json` deliberately and record the upstream tag or commit, checksum, and reason in the change.

## Release

Update `Rjq::VERSION` and `CHANGELOG.md` in one reviewed change. After CI passes, create and push a matching `vX.Y.Z` tag. `.github/workflows/release.yml` verifies the tag, reruns the gate, and publishes with RubyGems trusted publishing. The repository and `release.yml` workflow must first be registered as a RubyGems trusted publisher using the `release` environment.
