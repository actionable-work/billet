# Target capability preflight v1

`mkBillet.dockerCompose.capabilityReport` is pure evaluation over canonical IR.
The report contains schemaVersion 1, target `dockerCompose`, profileVersion 1,
rendererVersion 1, selected system, manifestDigest, requiredCapabilities, image
packaging eligibility, and deterministic diagnostics. Each diagnostic includes
code, field, capability and a reason without echoing field values. Unknown
required capabilities fail explicitly at requiredCapabilities.

Preflight never realizes a package, constructs an image, allocates a resource,
reads credentials or calls an engine. Linux image eligibility and runtime target
conformance are separate results. The generic system interface is not limited to
a consumer's initial x86_64-linux hosted profile.

The `compose-foundation-v1` profile claims no runtime capability. It returns
`canRender=false` and rejects required lifecycle, resource, probe, secret,
network, scaling/placement and storage semantics explicitly. Required defaults
are requirements too. `dockerCompose.configuration` throws an UnsupportedTarget
error containing owning field paths before forcing any image build. There is no
caller override that can assert unverified capability support. A new supported
profile needs actual target acceptance and a versioned capability change.

An OCI artifact may be built independently for image-content testing; its
existence does not make this profile renderable. Native Compose restart or
healthcheck settings alone cannot establish bounded durable recovery, complete
process-tree cleanup or rollout/rollback conformance. Generated configuration,
static validation and image smoke tests are not runtime capability evidence.
