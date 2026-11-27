# Semantic manifest diff

`billet diff BEFORE.json AFTER.json` compares two local Billet manifests. It
works directly on files and needs neither a Nix evaluator nor deployment
credentials. The existing artifact commands continue to take an installable.

## Reading manifests

Accept JSON object manifests with `schemaVersion` and `normalizationVersion`
both integer 1. Return exit 2 with an error on stderr and no diff on stdout for
usage, file, JSON, or unsupported-version errors. Version errors identify the
invalid side and field. Input diagnostics omit file contents and field values.
The Nix evaluator remains the authority for producing a valid manifest.

Reject repeated field names within any one JSON object. Canonical manifests have
one value per field, and a repeated name can hide a field's earlier value before
comparison or numeric validation. Report the affected input side with exit 2 and
empty stdout.

Open both arguments as native filesystem paths, including non-UTF-8 paths on
Unix. File errors identify the affected input side.

Canonical v1 numbers are signed 64-bit integers, with zero written as `0`.
Accept those integer tokens throughout the manifest, including in arrays. Reject
other number spellings or values outside the range with exit 2, the affected
input side on stderr, and empty stdout. Compare accepted integers exactly.

## Comparing manifests

Emit a JSON array of objects with `path` and `op` keys. Paths use JSON Pointer
with RFC 6901 escaping. Compare object fields by name in lexical order.
Equivalent JSON with different whitespace or object key order produces `[]` and
exit 0. A changed manifest produces exit 1. Emit `add` or `remove` at the path
of an added or removed field and `replace` at the changed leaf or container.
Treat arrays as ordered values and report a changed array at the array path.
This preserves the meaning of order-sensitive payloads such as argv. Report
paths and operations without including before or after values. Source lineage is
BI003 and BI010.

## Qualification

The CLI semantics check runs with no tools on `PATH` for the equivalent
manifests and asserts the exact operation array and exit code for the changed
manifests. Its array expectation covers path escaping, lexical order, subtree
addition and removal, array replacement, and value-free output. The error check
uses a separate invocation for each invalid input and asserts exit status, empty
stdout and the exact stderr text.

The numeric check compares neighboring integers at the signed 64-bit ceiling and
rejects exponent, fractional and out-of-range integer tokens. The path check
reads equivalent manifests whose filenames contain non-UTF-8 bytes and checks
the error for an unavailable path with those bytes. The error check also passes
duplicate names in nested objects and verifies that a later value cannot conceal
an unsupported earlier number.
