# Docker and Compose artifact delivery

Own the rendering and packaging contract in
`tests/.bloomery/specs/BILLET/IR/design/targets.md`. Implement Docker and Compose
from the unchanged canonical Billet IR. Runtime lifecycle and other renderer
families are outside this slice.

1. Preserve granular artifact requirements and update Compose requirements
   to describe artifact eligibility, exact image binding, and preserved
   runtime declarations.
2. Expose a Docker-loadable archive and a Compose configuration/file plus a
   directory with both and the canonical manifest. Add a build-only CLI
   action for the bundle.
3. Keep integration wiring in the registered test subflake. Verify the
   preflight and consume the actual archive and Compose bundle in a Docker
   VM. Retain the OCI and IR acceptance cases.
4. Record evidence, run the full native Bloomery and both flake checks, and
   commit the passing artifact-only slice.
