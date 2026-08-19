# ADR-NNNN: <Short Title>

**Status:** Proposed | Accepted | Superseded by ADR-XXXX
**Date:** YYYY-MM-DD
**Author:** <name>

## Context

What is the situation that requires a decision? What constraints (Constitution principles, existing ports, capability gaps, operational state) apply? Cite specific files, ports, ADRs.

## Decision

The single chosen path. Be concrete about the data flow, the ports used, the inputs and outputs. Reference `BOUNDARIES.md` rows and `CAPABILITIES.md` capabilities by name.

## Boundary

Every external surface this feature crosses:

- Which `BOUNDARIES.md` rows are reused (port + adapter).
- Whether any NEW boundary is introduced (if yes, name the port + write the semantic description for `CAPABILITIES.md`).
- Whether any vendor SDK is imported directly anywhere (must be only in an allowed adapter zone).

## Safety Rules

Invariants the implementation must preserve. Include:
- Authentication / authorization gates.
- Kill-switch interactions.
- Cost caps.
- Other governance rules that still apply.

## Cost Rationalization

Four required answers:
1. **Marginal cost** of one use of this feature.
2. **Steady-state cost** at the expected usage rate.
3. **Principled justification** for not using free-tier or self-hosted.
4. **Kill-switch + spend cap** — who turns it off and at what number.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| ... | ... |

## Acceptance Criteria

Numbered Tap → Expect statements (or equivalent for non-UI features). One must-pass test or human-handoff plan per criterion.

## Swap / Sunset Plan

If the chosen adapter or vendor goes away, what is the migration path? What is the review trigger that revisits this decision?
