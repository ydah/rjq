# Architecture

The execution path is deliberately split into explicit phases:

1. The lexer records token offsets and source names.
2. The parser builds filter and module-directive AST nodes.
3. `ModuleLoader` resolves dependencies through an injected resolver, evaluates constant metadata, and constructs namespaced definitions.
4. `BytecodeCompiler` lowers the executable AST to instructions and constants.
5. `SemanticAnalyzer` validates function and builtin names and arities before input is consumed.
6. `VM` executes enumerator-backed value streams.
7. `Runtime` coordinates incremental input records, input builtins, filenames, line numbers, and output budgets.
8. `JSON::Dumper` writes values directly to an IO without recursively building container output strings.

## Streaming model

`JSON::InputBuffer` reads fixed-size chunks. The normal parser yields complete top-level values; the stream parser yields path events within containers. `Runtime::InputQueue` adds one-record lookahead for `input` and `inputs`. Owned file handles are closed on completion, failure, and downstream early termination.

Array constructors, JSON slurp, raw slurp, sorting, grouping, uniqueness, and other jq aggregation boundaries collect by definition. Generators such as `range`, `recurse`, `repeat`, `while`, `until`, and `inputs` remain lazy so `first` and `limit` apply backpressure.

## Number model

`Rjq::Number` retains the original decimal literal and its binary64 value. Exact untouched literals use decimal components for equality and ordering without expanding large exponents. Arithmetic returns computed Ruby numeric values, which the dumper renders separately from untouched lexemes.

## Modules

Production code has no fixture-name fallback. `ModuleResolver` accepts explicit paths, canonicalizes real paths, and limits file size. `ModuleLoader` limits dependency depth, detects canonical cycles, caches parsed modules, handles data imports, and applies namespace rewriting to AST calls rather than source strings. Tests inject their own fixture resolver.

## Resource boundaries

JSON parsing uses jq's 256-container depth limit. Module bytes and dependency depth are limited. Embedded callers can
set `max_outputs` and `input_chunk_size`; `input_max_depth` can lower the parser depth limit. `max_number_digits` and
`max_string_bytes` are optional, unlimited by default, and stop oversized tokens incrementally before numeric
conversion or decoded-string growth. Public runtime and compiler APIs reject unknown options and invalid limits at
construction. Cyclic Ruby values and invalid JSON value types are rejected before copying or output.
