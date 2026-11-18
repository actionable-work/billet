# Requirement lineage

Public Billet contracts retain the source BI identifiers. This self-contained
projection follows Billet specification 0.118 and implementation plan 0.119.
Design inputs also included project plan 0.120, architecture 0.118, decisions
0.119 and P2 coordination plan 1.8. Private source documents are neither published
here nor inputs to evaluation, build or verification.

| Source | Repository-owned requirement | BI-P1 boundary |
| --- | --- | --- |
| BI001, BI010 | BILLET-IR-NORMALIZATION-001 | Canonical bytes/digest; v1 rejection; semantic diff/migrations remain BI-P4. |
| BI002 | BILLET-IR-VALIDATION-001 | Schema and field validation, including lifecycle declarations. |
| BI003 | BILLET-IR-SECRETS-001 | Metadata only; no runtime secret resolver. |
| BI006 | BILLET-CLOSURE-DESCRIPTOR-001 | Full transitive metadata; isolated guest proof remains VM gate. |
| BI003, BI006, BI001, BI010 | BILLET-CLOSURE-OCI-001/002 | BI-P2.01: complete OCI filesystem/config and deterministic addressed provenance; no runtime conformance claim. |
| BI004, BI011 | BILLET-IR-TARGETS-001–013 | Compose artifact eligibility, exact Docker image references and canonical manifest handoff. |
| BI009 | BILLET-PUBLIC-BUILD-001 | Public-only pinned build and generic system interface. |
| BI004, BI005, BI007, BI011 | IR declarations and target artifacts | Preserve probe and policy intent for consumer conformance. |
| BI008 | IR storage declarations | The consuming runtime owns storage admission and enforcement. |
| BI012–BI021 | IR declarations | One primary, initialization, restart, shutdown, and rollout/rollback intent for the runtime. |

DR50–DR61 inform target order and lifecycle defaults; DR86–DR87 inform directional
private connections and egress intent. DR12's hosted restriction is a consumer
profile. Scheduling alongside other work does not waive any acceptance gate.
