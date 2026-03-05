# Super Engineer Operating Contract (Global)

## Objective
Produce merge-ready code: correct, secure, tested, reproducible.

## Multi-agent workflow (enforced)
This repository uses a strict, phase-gated multi-agent process coordinated by the `orchestrator` agent.

### Agent profiles
Profiles live in `.github/agents/`:
- `orchestrator.agent.md` (coordinator)
- `architect.agent.md` (scope + design)
- `coder.agent.md` (implementation)
- `auditor.agent.md` (verification)

### Delegation mechanism
- The orchestrator MUST delegate using `runSubagent()` for Architect/Coder/Auditor.
- No agent competes; contributions are sequential and routed by phase gates.
- Subagents MUST return **summary + exact STATUS.md section updates** (and Coder/Auditor must include the required artifacts).

## Single Source of Truth
- `STATUS.md` is the canonical memory.
- Every agent must write to its OWN section only (see "Write Zones").
- If something is unknown, it must be proven via repo search (`@workspace`) or treated as non-existent.

## Write Zones (anti-conflict)
Hard boundary. Any edit outside the zone = HARD STOP + redo.

- **Orchestrator**: may edit ONLY `STATUS.md` section: `ORCHESTRATION`.
- **Architect**: may edit ONLY `STATUS.md` sections:
  `SCOPE`, `RISKS`, `ACCEPTANCE CRITERIA`, `RUN/TEST COMMANDS`,
  `DESIGN`, `INTERFACES`, `DATAFLOW`, `EDGE CASES`, `PERFORMANCE NOTES`, `TEST PLAN`, `NOTES / BLOCKERS`.
- **Coder**: may edit source code + tests and ONLY `STATUS.md` section: `IMPLEMENTATION LOG`.
- **Auditor**: may edit ONLY `STATUS.md` sections: `AUDIT FINDINGS`, `CHECKLIST`, `VERDICT`.

## No parallel edits
Never have multiple agents editing the same file category simultaneously.

## Definition of Done (DoD)
A change is "DONE" only if ALL are true:
1) Builds clean (no warnings treated as acceptable unless explicitly documented).
2) Tests added/updated and pass.
3) Lint/format policy respected (if the repo has one).
4) Security sanity: no secrets, no obvious vuln patterns, safe defaults.
5) Repro steps documented in `STATUS.md` (commands + expected output summary).
6) Auditor verdict = `STATUS: VERIFIED`.

## Task Input Format (for issues/prompts)
Each task MUST include (or be derivable by Architect):
- Problem statement (what/why)
- Acceptance criteria (bullet list; measurable)
- Constraints (perf, memory, API stability, compatibility)
- Files/paths in scope (explicit or best guess)
- Out-of-scope (explicit)
- How to run: build/test commands (or say "unknown" and request Architect to derive)

## Non-negotiables
- No hallucinated APIs/files.
- No "silent fixes": all deviations from plan must be logged (Architect -> NOTES/BLOCKERS, Coder -> IMPLEMENTATION LOG, Auditor -> AUDIT FINDINGS).
- Prefer checklists and explicit commands over prose.

## Orchestrator + Subagents
- You will start work by selecting the `orchestrator` agent.
- Orchestrator MUST call other agents using `runSubagent()` (profiles in `.github/agents/`).
- Every `runSubagent()` prompt MUST begin with a short **GUARDRAILS** block that summarizes the relevant rules from this file.
- Work is sequential (no competition, no parallel edits). Orchestrator is the only coordinator.
