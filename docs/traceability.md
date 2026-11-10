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
| BI009 | BILLET-PUBLIC-BUILD-001 | Public-only pinned build and generic system interface. |
| BI004, BI005, BI007, BI011 | BI-P2 / BI-P3 | Target conformance, probes, cleanup, policy and unsupported semantics. |
| BI008 | BI-P3 | Reject persistent claims in initial Lineshaft profile. |
| BI012–BI021 | IR declarations in BI-P1; execution in BI-P2/BI-P3 | One primary, init, restart, shutdown, rollout/rollback including current secret bindings. |

DR50–DR61 inform target order and lifecycle defaults; DR86–DR87 inform directional
private connections and egress intent. DR12's hosted restriction is a consumer
profile. Scheduling alongside other work does not waive any acceptance gate.
