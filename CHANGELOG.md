# Changelog

## Unreleased

- Added an independent jq 1.7.1 differential harness covering stdout, stderr, status, count, and order.
- Corrected top-level errors, halt behavior, CLI statuses, comments, syntax rejection, and builtin compile-time validation.
- Added raw-preserving numbers and multi-output filter semantics across interpolation, arguments, slices, reduce, foreach, and mapping.
- Replaced source-rewriting modules with parsed directives and an injected, bounded resolver.
- Added incremental normal and stream JSON parsing, lazy global input queues, multi-file slurp semantics, and early file closure.
- Added lazy generators, the remaining jq 1.7.1 builtin declarations, expanded math/format support, and UTC-stable date conversion.
- Added iterative JSON writing and deep copying, cyclic/type validation, parser depth limits, and optional output budgets.

