# Compatibility

`rjq` targets a practical subset of jq 1.7.1. Compatibility is tested at two levels:

- The bundled, adapted `jq.test` and `onig.test` fixtures exercise 447 and 40 cases. These tests use rjq's value model and are broad semantic regression tests, not proof of complete jq compatibility.
- The differential suite invokes an independently installed jq 1.7.1 executable and compares stdout bytes, normalized stderr, exit status, output count, and order. Run it with `JQ_BIN=/path/to/jq-1.7.1 bundle exec rake differential`.

The fixture source tag and file checksums are recorded in `spec/fixtures/jq/manifest.json`.

## Compatibility areas

| Area | Current contract |
| --- | --- |
| JSON numbers | Untouched decimal literals retain their lexeme; computed values use binary64-style rendering. |
| Filter streams | Pipes, commas, branching, interpolation, filter arguments, slices, reduce, foreach, range, recurse, repeat, while, and until preserve multiple outputs. |
| Errors | Compile, runtime, input parse, `halt`, `halt_error`, and `-e` statuses follow the jq status classes documented below. |
| Input | Top-level JSON and `--stream` parse incrementally. Multiple files form one logical stream; only slurp and aggregating filters intentionally collect. |
| Modules | Directives are parsed syntax, paths are canonicalized, fixture resolution is test-only, and traversal, symlink, size, depth, and cycle checks are enforced. |
| Regex | Ruby's regular-expression engine is used. jq's `m`, `s`, and `p` mode mapping is preserved; advanced Oniguruma behavior can differ. Ruby API callers may set `regexp_timeout` on runtimes that support per-expression timeouts. |
| Date/time | UTC conversion is host-timezone independent; platform date ranges can still differ. |
| Math | jq 1.7.1 builtin names and arities are declared. Bessel, fused multiply-add, IEEE remainder, and scaling functions use the platform C math library through `fiddle` when available. |

## Known differences

- This is not libjq and does not claim complete source, diagnostic-text, regex-engine, module-layout, or performance compatibility.
- Regex flag `l`, Unicode offsets, and advanced engine constructs can differ because Ruby Regexp is not jq's bundled Oniguruma build. In particular, zero-width matches on multibyte UTF-8 strings advance by codepoint in rjq and by byte in jq, so `split/2` can contain a different number of empty fields.
- On platforms without a native `fma` symbol, `fma/3` uses a non-fused multiply followed by add. Other native math functions have Ruby fallbacks, but extreme platform-specific results can differ.
- rjq extensions include `@base32`, `@base32d`, `dateadd`, `datesub`, `ascii`, `to_number`, and compatibility aliases such as `leaf_paths`.
- `get_jq_origin` reports the rjq installation root. Default module search paths are rjq's actual expanded paths, not jq's symbolic `$ORIGIN` entries.
- JSON object keys supplied through the Ruby API must be strings. Cyclic Ruby arrays and hashes are rejected.
- `env`, `now`, local time, module loading, file arguments, and diagnostic builtins access process capabilities unless the caller avoids those features or injects controlled options.

## Exit statuses

| Condition | Status |
| --- | ---: |
| Option or system usage error | 2 |
| Filter compile error | 3 |
| `-e` with no output | 4 |
| Runtime or input JSON error | 5 |
| `halt` | 0 |
| `halt_error(n)` | `n` |

## Ruby API values

Inputs and outputs are composed of `nil`, booleans, `Numeric`, UTF-8 `String`, `Array`, and `Hash` with string keys. Assignment operations copy affected values. Mutable strings are copied at constant and deep-copy boundaries. A compiled program may be reused sequentially; concurrent reuse has not yet been declared a stable guarantee.
