# rjq

`rjq` is a Ruby JSON processor implementing a practical jq 1.7.1-compatible subset with a command line and Ruby API.

The runtime uses its own incremental JSON parser and writer instead of Ruby's `json` library. The gem has no project-specific native extension; Bessel math functions call the platform C math library through `fiddle`.

## Installation

Install the gem and add it to your application's Gemfile by executing:

```sh
bundle add rjq
```

If bundler is not being used to manage dependencies, install the gem by executing:

```sh
gem install rjq
```

From a checkout, install dependencies and run the executable directly:

```sh
bundle install
bin/rjq --version
```

## Usage

Use `rjq` from the command line:

```sh
rjq '.foo | map(select(.active)) | .[].name' <<'JSON'
{"foo":[{"name":"Ada","active":true},{"name":"Linus","active":false}]}
JSON
```

Useful CLI examples:

```sh
rjq -c '[range(3)]' <<< 'null'
rjq -r '.message' <<< '{"message":"hello"}'
rjq --arg name Ada '{"hello": $name}' <<< 'null'
rjq -n '[inputs]' <<< $'1\n2\n3'
```

Use `rjq` as a Ruby library:

```ruby
require "rjq"

Rjq.run(".foo | .[]", {"foo" => [1, 2, 3]}).to_a
# => [1, 2, 3]

# Optional resource limits for untrusted JSON input and filters:
Rjq.run_stream(".", io: input_io, opts: {
  input_chunk_size: 16_384,
  input_max_depth: 128,
  max_number_digits: 1_000,
  max_string_bytes: 1_048_576,
  max_outputs: 10_000,
  regexp_timeout: 0.1
}).to_a
```

`max_number_digits` counts all digits in a JSON number literal, including fractional and exponent digits.
`max_string_bytes` limits each decoded JSON string (including object keys) by UTF-8 byte size. Both default to
`nil` (unlimited) for jq compatibility. Invalid or unknown Ruby API options are rejected before compilation or input
processing. Passing `nil` for `stderr` or `module_resolver` selects the normal process stderr or default module
resolver, respectively. Option hashes and their `variables` and `library_path` containers are copied before lazy
execution begins.

Inspect compiled bytecode:

```ruby
puts Rjq.compile(".foo | .[]").disasm
```

## Compatibility

The current implementation passes the bundled, adapted jq 1.7.1 regression fixtures:

```sh
ruby script/official_compat.rb
# checked=447 failures=0

ruby script/official_compat.rb spec/fixtures/jq/onig.test
# checked=40 failures=0
```

The same fixtures are integrated into RSpec under `spec/compat`, so CI runs them as normal tests. Fixture success uses rjq's own value model and is not presented as proof of complete jq compatibility.

An independent differential suite invokes a checksum-pinned jq 1.7.1 executable and compares stdout bytes, normalized stderr, exit status, output count, and ordering:

```sh
JQ_BIN=/path/to/jq-1.7.1 bundle exec rake differential
```

Supported areas include:

- jq values, ordering, truthiness, and numeric edge cases
- incremental JSON parser and direct writer, including jq-style `NaN`, `Infinity`, and `-0`
- jq-compatible `--stream` input, including close markers, and `--stream-errors` parse-error arrays
- field/index/slice access, iteration, pipes, commas, conditionals, `try/catch`, labels and breaks
- bindings, structured bindings, functions, local `def`, filter arguments, and recursive functions
- path expressions, assignment/update operators, `del`, `getpath`, `setpath`, `delpaths`
- core, array, string, math, date/time, format, SQL-style, stream, and regex builtins
- `jq.test` success cases, `%%FAIL` rejection cases, and `onig.test` success cases

See [COMPATIBILITY.md](COMPATIBILITY.md) for the compatibility contract, known differences, exit statuses, extensions, and accepted Ruby value types.

## Bytecode VM

`Rjq.compile` parses filters into an AST, compiles the executable filter body into a bytecode `Rjq::Program`, then runs that program through `Rjq::VM`.

The VM is a stack machine with explicit instructions such as:

- `load_input`, `load_const`, `field`, `index_const`, `index_filter`, `slice_const`, `each`
- `path`, `pipe`, `append`, `array`, `object`, `call`, `unary`, `binary`, `branch`
- `try`, `reduce`, `foreach`, `label`, `break`, `assign`, `scoped_def`, `recurse`

All parsed AST nodes used by the runtime are lowered to bytecode. Path expressions, update assignment,
`try/catch`, local `def`, recursion, and module metadata are handled by VM instructions and runtime context
rather than an `eval_node` fallback.

The VM stores instruction results as enumerator-backed streams on the stack. `each`, `pipe`, comma-style append,
branching, binary cross-products, object construction, `reduce`, `foreach`, local function calls, filter arguments,
recursion, `range`, `repeat`, `while`, `until`, and input builtins preserve continuations lazily. Array constructors,
slurp, and aggregating builtins collect only at the jq semantic boundaries that require a complete value. Input files
and stream events are read incrementally and owned file handles close when downstream evaluation stops early.

See [ARCHITECTURE.md](ARCHITECTURE.md) for execution phases, number semantics, module resolution, streaming, and resource boundaries.

## Development

After checking out the repo, run:

```sh
bundle install
bundle exec rake
```

This runs:

- RSpec, including `spec/compat`
- `script/compat_probe.rb`

Individual checks:

```sh
bundle exec rake spec
bundle exec rake compat
bundle exec rake differential
ruby script/official_compat.rb
ruby script/official_compat.rb spec/fixtures/jq/onig.test
```

Run the benchmark suite:

```sh
ruby benchmark/jq_compare.rb
```

If `jq` is available on `PATH`, the benchmark prints a Markdown comparison table and checks stdout equality. Increase the sample size with:

```sh
ITERATIONS=50 ruby benchmark/jq_compare.rb
```

GitHub Actions runs the suite on Ruby 3.1 through 4.0 plus experimental Ruby head, runs a macOS portability job,
executes the pinned jq 1.7.1 differential suite, and builds and installs the gem as a smoke test.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ydah/rjq. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
