# GUARDRAILS — Universal Copilot Instructions

These rules apply to **every agent** in this repository without exception. Orchestrator must include this section verbatim when calling `runSubagent()`.

---

## Core Principles

1. **One agent active at a time.** Execution is sequential; no parallel agents.
2. **Strict write-zones.** Each agent may only modify files in its declared write-zone. Violations must be rejected.
3. **STATUS.md is the single source of truth.** All state transitions, decisions, and outcomes are recorded there.
4. **REDO on failure.** If any gate fails, Orchestrator routes back to the responsible agent with a full defect report.
5. **No scope creep.** Agents must not change acceptance criteria, design decisions, or task scope without routing back to Architect.
6. **No secrets in code.** Environment variables only; never commit credentials.
7. **All languages supported.** Agents must handle any programming language, framework, or platform without bias.
8. **Error = REDO.** Any unresolved error, failing test, or unmet acceptance criterion triggers a REDO cycle before proceeding.

---

## Mandatory STATUS.md Protocol

Every agent that completes a phase **must** update `STATUS.md` in its designated section before passing control back to Orchestrator.

```
STATUS: VERIFIED | REDO | IN_PROGRESS
AGENT: <agent-name>
PHASE: <phase-name>
TIMESTAMP: <ISO-8601>
DETAILS: <brief description of outcome>
```

---

## Routing Rules Summary (for Orchestrator)

| Condition | Trigger agents |
|---|---|
| Any task | Orchestrator + Coder + Auditor (minimum) |
| Fast-path (≤2 files, no API/arch change, no new deps) | Coder → Auditor |
| Bug / crash / regression / unclear root cause | Issue Analyst → Coder → [QA] → Auditor |
| New feature / architecture change / ≥2 modules | + Architect |
| Behaviour change / bug without test | + QA |
| User input / auth / secrets / deps update | + Security |
| Hot paths / large data / latency requirements | + Performance |
| CI failure / build system / lint / dep changes | + DX-CI |
| Public interface / CLI / env config change | + Docs |
| Explicit refactor-maintainer / cleanup / tech-debt task | + Refactor |

---

## Anti-Conflict Rules

- Architect, Issue Analyst, QA, Security, Performance, Auditor → **read code, write STATUS.md and recommendations only**.
- Coder, Refactor → **write code and tests within scope**.
- DX-CI → **write CI configs and tooling configs only**.
- Docs → **write documentation files only**.
- No "Reviewer2" pattern: each specialist has a unique, non-overlapping checklist.

---

## Language & Technology Guidelines

- Support all languages: Python, JavaScript/TypeScript, Go, Rust, C#, Java, PHP, Ruby, C/C++, and more.
- Use the language's idiomatic patterns and tools (e.g., `cargo` for Rust, `npm`/`pnpm` for Node, `pip`/`uv` for Python).
- Follow the project's existing style and conventions first; fall back to language-standard style guides.
- Write tests using the project's existing test framework; do not introduce new frameworks without Architect approval.

### Command Matrix (fallback — use only if repo provides no guidance)

| Language / Stack | Build | Test | Lint / Format |
|---|---|---|---|
| Node.js / TypeScript | `npm run build` / `tsc` | `npm test` / `pnpm test` | `npm run lint` / `eslint` / `prettier` |
| Python | `(none)` / `pip install -e .` | `pytest -q` | `ruff check .` / `mypy .` |
| Go | `go build ./...` | `go test ./...` | `go vet ./...` / `golangci-lint run` |
| Rust | `cargo build` | `cargo test` | `cargo clippy` / `cargo fmt` |
| C# / .NET | `dotnet build` | `dotnet test` | `dotnet format` |
| Java / Maven | `mvn package -q` | `mvn test` | `mvn checkstyle:check` |
| Java / Gradle | `./gradlew build` | `./gradlew test` | `./gradlew checkstyleMain` |
| PHP / Composer | `composer install` | `./vendor/bin/phpunit` | `./vendor/bin/phpcs` |
| Ruby | `bundle install` | `bundle exec rspec` | `bundle exec rubocop` |
| C / C++ / CMake | `cmake -B build && cmake --build build` | `ctest --test-dir build` | `clang-tidy` |

Architect and Issue Analyst must discover and record the **actual** commands from the repository (README, `package.json`, `Makefile`, CI config) before falling back to this matrix.

---

## Gates

| Gate | Condition to pass | Failure action |
|---|---|---|
| Design Gate | Architect marks design VERIFIED | REDO → Architect |
| Implementation Gate | All tests pass, acceptance criteria met | REDO → Coder |
| Review Gate | Auditor marks VERIFIED | REDO → responsible agent |
| Merge Gate | All previous gates VERIFIED | Block merge |
