# rjq

`rjq` is a pure Ruby JSON processor with a jq-compatible command line and Ruby API.

The runtime uses its own JSON parser and dumper instead of Ruby's `json` library.

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
```

Inspect compiled bytecode:

```ruby
puts Rjq.compile(".foo | .[]").disasm
```

## Compatibility

The current implementation passes the bundled jq 1.7.1 compatibility fixtures:

```sh
ruby script/official_compat.rb
# checked=447 failures=0

ruby script/official_compat.rb spec/fixtures/jq/onig.test
# checked=40 failures=0
```

The same fixtures are integrated into RSpec under `spec/compat`, so CI runs them as normal tests.

Supported areas include:

- jq values, ordering, truthiness, and numeric edge cases
- pure Ruby JSON parser/dumper, including jq-style `NaN`, `Infinity`, and `-0`
- jq-compatible `--stream` input, including close markers, and `--stream-errors` parse-error arrays
- field/index/slice access, iteration, pipes, commas, conditionals, `try/catch`, labels and breaks
- bindings, structured bindings, functions, local `def`, filter arguments, and recursive functions
- path expressions, assignment/update operators, `del`, `getpath`, `setpath`, `delpaths`
- core, array, string, math, date/time, format, SQL-style, stream, and regex builtins
- `jq.test` success cases, `%%FAIL` rejection cases, and `onig.test` success cases

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
and recursion preserve continuations lazily. Array constructors and aggregating builtins collect only at the jq
semantic boundaries that require a complete value.

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

GitHub Actions runs `bundle exec rake` on Ruby 3.1, 3.2, 3.3, and 3.4.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ydah/rjq.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
