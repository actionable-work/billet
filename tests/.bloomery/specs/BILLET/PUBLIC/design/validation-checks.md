# Validation derivations

A service exposes `validationCheck`. Selecting the check fully evaluates its
normalized IR. The check writes the manifest digest without realizing the
application package.

A bundle exposes the same check attribute. Selecting it requires a nonempty
member set, valid member IRs, matching identity and member keys, and a single
system matching the package set. The check writes the manifest digests keyed by
member name. Compose eligibility and artifact builds have their own selectors.

A Bloomery application publishes services and bundles by returning the named set
from `mkFlake.billets`. Their validation derivations are available through the
normal flake check interface.
