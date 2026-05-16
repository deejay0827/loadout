# Development Practice — LoadOut

```
================================================================================
WHAT THIS DOCUMENT IS
================================================================================
The canonical reference for HOW work gets done on LoadOut. Three parties
(operator, chat-Claude, Claude Code), three pairs of eyes, halt-and-validate
groups, .md spec handoffs, sequential phase production.

This document captures the workflow we actually use — not aspirations.
If the workflow diverges from this doc, update the doc.

================================================================================
WHO THIS DOCUMENT IS FOR
================================================================================
- A new chat-Claude session starting fresh — read this before writing a
  phase spec, designing a feature, or analyzing code.
- A new Claude Code session receiving a spec — read this before executing
  groups, generating reports, or pushing commits.
- The operator (you) — institutional memory + the doc to hand a
  collaborator if work ever distributes.

If you're a Claude session: read CLAUDE.md first for product context, then
this doc for process context, then the relevant facet doc (Marketing.md /
Engineering.md / Ballistics.md / UI.md) for the area you're working in.
```

---

## 1. Three roles, three pairs of eyes

LoadOut is built by three parties working sequentially, never in parallel. Each pair of eyes catches what the previous pair missed.

### 1.1 Operator (human)

Owns the project. Makes every design call that has options. Picks the path when chat-Claude offers candidates. Runs Claude Code with the chat-produced spec. Reports results back to chat. Decides whether a phase is closed or needs a follow-up.

The operator's job is **decision-making and continuity**, not code-writing. Code-writing is delegated to Claude Code. Analysis is delegated to chat-Claude. The operator is the only party with persistent memory across sessions — the AI sessions don't share memory with each other.

### 1.2 Chat-Claude

This is the analysis + design + spec-writing role. Lives in claude.ai chat sessions. Reads existing code (the operator uploads relevant files). Audits for bad patterns. Proposes designs. Writes phase specs as .md files the operator can hand to Claude Code.

Chat-Claude does NOT push commits. Chat-Claude does NOT modify the repo. Chat-Claude's deliverables are .md files saved to `/mnt/user-data/outputs/` and presented for the operator to download.

Chat-Claude's job is **removing ambiguity**. The spec it produces should let Claude Code execute without making design calls. If chat-Claude finds itself writing "Claude Code decides X," it has done its job poorly — the design call belongs in chat, not in execution.

### 1.3 Claude Code

The execution role. Lives in Claude Code CLI / desktop app sessions. Receives a phase spec as a .md file. Executes the spec one group at a time. Pushes commits. Runs validation gates (`flutter analyze`, `flutter test`). Reports per-group findings to the operator. Flags red flags. Asks questions only when the spec is genuinely ambiguous.

Claude Code does NOT design. Claude Code does NOT improvise. Claude Code does NOT batch "while I'm in here" cleanups. If the spec says "rename file X to Y," Claude Code renames file X to Y — not "rename X to Y and also fix the unrelated bug in Z while you're at it." Unrelated work gets reported as a red flag, not silently bundled.

Claude Code's job is **disciplined execution and honest reporting**. The execution part means following the spec. The honest reporting part means raising surprises early — a missing file, an unexpected test failure, a design assumption that doesn't match reality.

### 1.4 The hand-offs

```
                  ┌──────────────────────────────────────────┐
                  │  Operator                                │
                  │  - owns the project                      │
                  │  - makes design decisions                │
                  │  - hands specs to Claude Code            │
                  │  - reports results back to chat          │
                  └──────────────────────────────────────────┘
                       ↓ uploads files, asks questions
                       ↑ returns answers, decisions, results
                  ┌──────────────────────────────────────────┐
                  │  Chat-Claude                             │
                  │  - reads uploaded files                  │
                  │  - analyzes for bad patterns             │
                  │  - proposes designs                      │
                  │  - writes .md specs                      │
                  │  - waits for operator confirmation       │
                  └──────────────────────────────────────────┘
                       ↓ operator downloads .md spec
                       ↓ operator hands .md to Claude Code
                  ┌──────────────────────────────────────────┐
                  │  Claude Code                             │
                  │  - reads the spec                        │
                  │  - executes group by group               │
                  │  - pushes commits to main                │
                  │  - reports per group                     │
                  │  - flags red flags                       │
                  └──────────────────────────────────────────┘
                       ↓ operator relays Claude Code's report
                       ↓ back to chat for next phase planning
```

The loop closes when chat-Claude receives the Phase N report and produces the Phase N+1 spec — not before.

---

## 2. Phases and groups

### 2.1 Phases

A **phase** is a bounded body of work with a clear theme. Examples from LoadOut's history:

- Phase One — Recipes: Unified Smart Import + Targeted Cleanup
- Phase Two — Recipes: Hardcoded Data Cleanup
- Phase Three — Recipes: Bad Designs Cleanup
- Phase 10 — Scene Painter: Polished Mode + Visual Style Toggle (audit cycle in flight)

Naming: `Phase N — <Area>: <Theme>`. The number is for ordering across the whole project, not per-area. Phase Six in the painter work and Phase Seven in the recipes work are not "the same phase" — they're sequential project-wide phases.

A phase contains:

- **Scope section** — what's in, what's out, what's deferred to a future phase, what's out of scope for this chat (because it belongs to a different chat's area).
- **Pre-flight** — baseline confirmations the operator runs before Group 1.
- **A sequence of groups** — typically 4-8.
- **Appendices** — file inventory after the phase, validation gates, deliberate non-goals, sequencing summary.

A phase is the right size when it solves one coherent problem and ships in one to two weeks of operator + Claude Code time. If a phase has more than ~10 groups, it's two phases stapled together.

### 2.2 Groups

A **group** is the unit of execution within a phase. One group = one logical change = one commit = one push to `main` = one halt + operator confirmation before the next group starts.

This is **halt-and-validate**, not "submit all five groups at once and we'll see how it goes." It's real, not advisory. Reverts target individual groups, so each commit is the unit of revert too.

Within a group, the work is:

1. Single logical change. "Rename file X to Y" is one group. "Rename file X to Y AND refactor the autosave path" is two.
2. Commit + push to `main` (per the auto-commit / auto-merge workflow — Engineering.md § 13).
3. Run the validation gates: `flutter analyze`, `flutter test`.
4. Emit the **full per-group report** — VALIDATION, COMMITS, WORK PERFORMED, FINDINGS, NOTES, DISCUSSION POINTS, CONCERNS, FIXES, RED FLAGS. Template in § 5.1.
5. **HALT.** Stop. Do not proceed. Wait for the operator's explicit go-ahead. The halt protocol is § 5.3 and is not advisory.

Don't batch. Don't combine "while I'm in here" cleanups. Don't push two groups in one commit because they're related. If a group's work has to expand because of a discovered issue, ask first — don't silently expand scope.

---

## 3. The .md spec format

A phase spec is a markdown file. The operator downloads it from chat, hands it to Claude Code, and expects Claude Code to be able to execute it without further input.

### 3.1 Required sections

In order:

1. **Header** — phase number, title, workflow-rule reference, per-group report format.
2. **Why this phase exists** — one or two paragraphs of motivation. What's broken / what's missing / why now.
3. **Scope** — in scope, out of scope (deferred to phase N+M), out of scope (other chats).
4. **Pre-flight** — baseline commands the operator runs before Group 1. Files Claude Code should read end-to-end. Sessions that must be prerequisite-complete.
5. **Per-group sections** — Group 1, Group 2, … Each group has:
   - **Goal** — one paragraph.
   - **Why this is the right design** — only included when the redesign isn't obvious or has alternatives the operator should know were rejected.
   - **Files touched** — explicit list. NEW files marked. DELETED files marked.
   - **What changes** — concrete description with code where helpful.
   - **What does NOT change** — explicit guardrails to prevent silent scope expansion.
   - **Validation** — what `flutter analyze` and `flutter test` should look like; what manual smoke flows must pass.
   - **Report** — the exact format Claude Code uses for the group's wrap-up.
   - **Halt line** — "Halt for operator confirmation."
6. **Appendices**:
   - A: File inventory after the phase.
   - B: Validation gates (cumulative across groups).
   - C: Things this spec deliberately does NOT do.
   - D: Sequencing summary (a flow diagram or numbered list).

### 3.2 Level of detail

The standard is **"Claude Code never has to make a design call."** Concretely:

- **Schemas.** Spec includes the literal Dart class / enum / table definition, not "add a class with these fields."
- **Method signatures.** Spec includes the exact method signature, including return type and parameter names.
- **File paths.** Spec includes the full path from repo root, not "somewhere under `lib/screens/`."
- **Migration mechanics.** Schema bumps include the exact migration step (`m.createTable(...)` or whatever).
- **Sequencing inside a group.** Where a group has multiple substeps, the spec lists them in order with the rationale for the order.
- **What does NOT change.** Anti-goals are listed explicitly so Claude Code can confirm it didn't drift.

A spec that says "rename the file to something clearer" is too loose. The right form is "rename `smart_import_screen.dart` to `spreadsheet_import_screen.dart`."

A spec that says "add a method on `ComponentRepository` that maps diameters to caliber labels" is too loose. The right form is the full method signature plus the tolerance value plus the tie-breaker rule plus the fallback behavior.

### 3.3 What "no ambiguity" looks like

Ambiguity test: read the spec as if you were Claude Code. For every decision the spec implies, ask "could I do this two different ways?" If the answer is yes, the spec is ambiguous — add a clarifier.

Concrete ambiguity patterns to avoid:

- **"The right shape"** without saying what the right shape is.
- **"Choose the cleanest path"** — the spec author should have already chosen.
- **"Update tests appropriately"** — say what specific test cases must exist after the change.
- **"Refactor related code as needed"** — never as-needed. Only what the spec explicitly lists.
- **"TBD"** in a group body — never. TBDs belong in the Phase N+1 queue, not in an executable group.

The audit-pending tag is allowed: `**AUDIT-PENDING (Phase N item #M).**` That's a flag that future work will resolve the question, NOT a hand-wave that lets Claude Code resolve it now.

### 3.4 Initial code in specs

Specs include initial code (class definitions, method signatures, enum values, JSON shapes) when:

- The shape is non-obvious from the natural-language description.
- There's exactly one right answer and writing it once in the spec is faster than writing the same thing in chat reviews.
- The code touches the type system in a way that has downstream implications.

Specs do NOT include initial code for:

- Mechanical changes (file renames, import path updates).
- Internal implementation details that don't affect callers.
- Anything where Claude Code's judgment matches the operator's judgment.

The rule of thumb: **code-in-spec is for shape definitions, not for filling out the body of a function.** Chat-Claude writes the data class; Claude Code writes the SQL inside the migration step.

---

## 4. The phase lifecycle

### 4.1 Step 1 — Design (chat + operator)

Operator opens a chat session and uploads relevant files. Chat-Claude reads them, surfaces bad code / bad designs / hardcoded items / fragile patterns. Operator picks which items to address in the next phase, defers others.

Design happens in conversation. Chat-Claude proposes; operator picks; chat-Claude proposes the next layer of detail; operator picks again. The chat session is the design forum. By the end, every design call has an answer.

**The audit cycle** is invoked when the design is in unknown territory (e.g. visual-style infrastructure, new persistence layer). Process:

1. Chat-Claude writes a first-draft spec tagged `AUDIT-PENDING`.
2. Operator hands the draft to Claude Code with the audit prompt (read-only; no commits).
3. Claude Code returns a critique.
4. Operator relays the critique to chat-Claude.
5. Chat-Claude revises.
6. The final spec ships for execution.

The audit cycle is opt-in. For mechanical or well-understood changes (file renames, simple schema bumps), skip it.

### 4.2 Step 2 — Spec authoring (chat)

Chat-Claude writes the phase spec as a .md file. The spec follows § 3 (required sections, level of detail). Saved to `/mnt/user-data/outputs/`. Presented to the operator via `present_files`.

If the spec also requires a doc update (most do — Engineering.md is the most common), chat-Claude writes the updated doc as a separate .md file in the same output directory. Two deliverables per phase: the spec, and the docs-target.

### 4.3 Step 3 — Operator review

Operator reads the spec. Spots gaps, ambiguities, scope creep, dropped requirements. Comes back to chat with edits. Chat-Claude revises until the spec is operator-approved.

This step is where most phase-quality risk lives. Skipping it ships a bad spec to Claude Code, who then either (a) executes the bad spec faithfully and produces wrong code, or (b) catches the issue and stalls waiting for clarification. Either way, the operator's review time was deferred to a more expensive place. Read the spec.

### 4.4 Step 4 — Execution (Claude Code)

Operator hands the spec to Claude Code. Claude Code executes one group at a time.

Per group:

1. Read the group's scope.
2. Make the changes the spec specifies.
3. Run `flutter analyze`. If issues exceed the expected baseline, halt and report.
4. Run `flutter test`. If tests fail, halt and report.
5. Run the manual smoke flows the spec lists. If any fail, halt and report.
6. Commit + push to `main`.
7. **Emit the full per-group report** — VALIDATION + COMMITS + WORK PERFORMED + FINDINGS + NOTES + DISCUSSION POINTS + CONCERNS + FIXES + RED FLAGS (template in § 5.1). Sections that have nothing to say use "None" — don't omit them.
8. **HALT. Stop emitting work. Wait for the operator's explicit go-ahead before Group N+1.** Halt protocol is § 5.3.

If anything during a group is surprising — a file isn't where the spec said it would be, a schema doesn't match the spec's assumptions, a test that should still pass starts failing — Claude Code halts BEFORE committing and asks the operator. Surprises are not silently absorbed.

### 4.5 Step 5 — Per-group reports

After each group, Claude Code emits a structured report (§ 5.1). Operator confirms before Group N+1 starts. Operator may also need to relay something — a question from Claude Code, an unexpected analyze count, a partial-pass test result — back to chat-Claude for adjudication.

### 4.6 Step 6 — Phase close-out

After the final group, Claude Code emits a phase-level report (§ 5.2). Operator confirms phase complete.

### 4.7 Step 7 — Next-phase trigger

**Critical rule: chat-Claude does NOT write the Phase N+1 spec until the operator reports Phase N is closed.**

Why: Phase N's execution often surfaces bugs, ambiguities, or design adjustments that need to land in Phase N+1. Writing Phase N+1 in advance risks (a) the operator running outdated specs and (b) chat-Claude planning around stale assumptions.

When the operator returns with the Phase N close-out report, chat-Claude can:

- Adjust Phase N+1's baseline numbers (analyze + test counts) to match Phase N's final state.
- Fold any bug fixes from Phase N into Phase N+1's pre-flight or Group 1.
- Reorder groups based on what Phase N revealed.
- Drop or add groups based on operator priorities that emerged during Phase N.

The phase lifecycle is sequential, not pipelined. One in flight at a time.

---

## 5. Reports

Reports are how Claude Code makes its work legible to the operator and to the next chat-Claude session. The format is structured and required — terse free-form prose is not acceptable. The operator should be able to read a per-group report in 60 seconds and know exactly what happened, what's safe to confirm, and what needs to escalate.

There are two report types: **per-group** (after every group) and **end-of-phase** (after the final group). Plus a **halt protocol** (§ 5.3) that governs what Claude Code does after emitting either report.

### 5.1 Per-group report format

After each group, Claude Code emits the following report in the chat. Every section is required. "None" is an acceptable value where the section truly has nothing to say — don't fabricate content to fill space.

```
═══════════════════════════════════════════════════════════════
GROUP N REPORT — <title from spec>
═══════════════════════════════════════════════════════════════

VALIDATION
──────────
  flutter analyze: <issues>, <errors>     (baseline: <N>, expected: <X>)
  flutter test:    <pass>/<total>          (baseline: <T>, expected: <Y>)
  Cold restart:    yes | no
  Manual smoke:    pass | n/a | partial — <details if partial or failing>

COMMITS (this group)
────────────────────
  <short hash>  <subject line>
  <short hash>  <subject line>     (if multiple — rare; should usually be one)

WORK PERFORMED
──────────────
  New files:
    + <path>  — <one-line role>
  Modified:
    ~ <path>  — <one-line nature of change>
  Renamed:
    → <old path> → <new path>
  Deleted:
    - <path>  — <one-line reason>
  Other (config, schema, migration, generated code):
    • <one-line description per item>

FINDINGS
────────
  What Claude Code learned while doing the work — existing patterns,
  hidden dependencies, schema realities, related code paths that
  needed touching, conventions discovered, etc. Bullet points.
  This is the "what I learned reading the code" section and is
  often the most valuable content for the next chat-Claude session.

NOTES
─────
  Observations worth flagging that don't rise to red-flag level.
  Things that were considered but not done. Side observations.
  Performance / size / readability notes. "None" if there are none.

DISCUSSION POINTS
─────────────────
  Open questions surfaced by this group's work. Architecture ideas
  that emerged. Topics for future-phase planning. These don't need
  resolution now — they're the inputs to the next chat-Claude
  session. "None" if there are none.

CONCERNS
────────
  Brittle areas. Patterns that should be revisited. Tests that
  pass but probably shouldn't. Areas of the code that worked
  this time but won't scale. "None" if there are none.

FIXES (incidental, in-scope)
────────────────────────────
  Bugs or issues found AND addressed in this group within the
  spec's scope. List each with a one-line description so the
  operator can decide whether to call them out in the changelog.
  "None" if there were none.

RED FLAGS (operator attention required before next group)
─────────────────────────────────────────────────────────
  Critical issues that need operator decisions BEFORE Group N+1
  starts. Spec assumptions that turned out wrong. Security or
  privacy concerns. Things requiring a design call. "None" if
  there were none.

═══════════════════════════════════════════════════════════════
⏸  HALT — END OF GROUP N

Claude Code: STOP HERE. Do not start Group N+1 until the operator
explicitly says "proceed" or equivalent unambiguous go-ahead.

If RED FLAGS above are not "none", the operator MUST relay them
to chat-Claude before Group N+1 starts. Do not absorb red flags
into the next group's scope without a chat-level decision.
═══════════════════════════════════════════════════════════════
```

**Why every section is required.** Each one answers a question the operator (and the next chat-Claude session) reliably has:

- VALIDATION → "Is the build still healthy?"
- COMMITS → "What exactly landed on `main`?"
- WORK PERFORMED → "What's the file-level diff at a glance?"
- FINDINGS → "What does future-me need to know about this code path?"
- NOTES → "Anything I'd want to flag if I had 30 more seconds?"
- DISCUSSION POINTS → "What should chat-Claude think about for the next phase?"
- CONCERNS → "What's fragile that I touched but didn't fix?"
- FIXES → "Did anything change beyond the spec?"
- RED FLAGS → "Should the operator stop me before the next group?"

### 5.2 End-of-phase report

After the final group, Claude Code emits an aggregated phase-level report. This is the document the operator hands back to chat-Claude to plan the next phase.

```
═══════════════════════════════════════════════════════════════
PHASE N COMPLETE — <title from spec>
═══════════════════════════════════════════════════════════════

EXECUTIVE SUMMARY
─────────────────
  2-4 sentences describing what shipped at the phase level.
  This is what gets pasted into LOADOUT_PROJECT_HANDOFF.md
  and relayed to the next chat-Claude session.

GROUP-BY-GROUP SUMMARY
──────────────────────
  Group 1: <title> — <one-line outcome>
  Group 2: <title> — <one-line outcome>
  ...
  Group N: <title> — <one-line outcome>

FINAL STATE
───────────
  flutter analyze:   <count>, 0 errors        (delta from baseline: <Δ>)
  flutter test:      <pass>/<total>           (delta: <+N>)
  Schema version:    <N>                       (was <N-k>)
  Manifest version:  <N>                       (was <N-k>)
  New files:         <count>
    <list of paths>
  Renamed files:     <count>
    <list of old → new>
  Deleted files:     <count>
    <list of paths>
  New dependencies:  <list, or "none">

ALL COMMITS IN THIS PHASE
─────────────────────────
  <hash>  Group 1: <subject>
  <hash>  Group 2: <subject>
  ...
  <hash>  Group N: <subject>

AGGREGATE FINDINGS
──────────────────
  Cross-group findings worth surfacing at the phase level —
  patterns that emerged, architectural insights, conventions
  that should be documented in Engineering.md or DEVELOPMENT.md.

UNRESOLVED RED FLAGS
────────────────────
  Anything raised during groups that wasn't fully addressed by
  the end of the phase. These usually become Phase N+1 candidates.
  "None" if every flag landed.

DEFERRED ITEMS
──────────────
  Operator decisions that were noted but deferred to the next
  phase planning session. Each item should have enough context
  for chat-Claude to pick up cold.

PHASE QUEUE UPDATES
───────────────────
  Resolved this phase:    <items from the original queue that landed>
  Added during execution: <items discovered during the phase>
  Reordered:              <items whose priority shifted>

OPEN QUESTIONS FOR CHAT-CLAUDE
──────────────────────────────
  Specific things the operator should relay back to chat-Claude
  when planning Phase N+1. Each as a stand-alone question with
  enough context to answer without re-reading the whole phase.

═══════════════════════════════════════════════════════════════
PHASE N CLOSED.

Operator: relay this report to chat-Claude when ready to plan
Phase N+1. Do not start Phase N+1 work in Claude Code until
chat-Claude has produced and operator-reviewed the new spec.
═══════════════════════════════════════════════════════════════
```

### 5.3 Halt protocol

The halt at every group boundary is **not advisory**. Claude Code stops emitting work after the per-group report, full stop, until the operator explicitly confirms.

**What "explicitly confirms" means.** A clear go-ahead like:

- "proceed"
- "go ahead with Group N+1"
- "looks good, continue"
- Or operator-supplied adjustments followed by a clear go-ahead.

**What is NOT a confirmation:**

- Silence (Claude Code does not "assume the operator is happy" after a delay).
- A question from the operator about something in the report (Claude Code answers the question and waits again).
- A "thanks" without a continue directive (acknowledgement, not authorization).
- A change request followed by "...then continue" — Claude Code addresses the change request as its own group or as an in-place fix to the just-completed group, depending on operator instruction, but does NOT roll the change into Group N+1.

**When red flags are non-empty.** The halt becomes mandatory regardless of the operator's first response. Claude Code does not start Group N+1 even with operator "proceed" if red flags are unresolved — the operator must explicitly acknowledge each red flag (resolve, defer to a later phase, or accept the risk in writing). This protects against accidentally moving past a flagged issue.

**When the operator is offline / unavailable.** Claude Code's halt waits. No timeout. No "I'll start Group N+1 in 10 minutes if you don't reply." The whole point is that the operator is the gate.

**Inside a group, before the halt.** Claude Code may halt mid-group if:

- A spec assumption fails (file not where the spec said, schema column missing, etc.).
- A test that was passing breaks for non-obvious reasons.
- A hard-fenced file (Engineering.md § 12) needs to be touched.
- The change Claude Code is about to make would touch >10 files when the spec implied <5 — surface, do not proceed.

In all of these cases, Claude Code reports what it found and halts BEFORE committing. The operator decides whether to adjust the spec, defer the work, or accept the surprise.

### 5.4 What counts as a red flag

Claude Code raises a red flag when:

- A spec assumption doesn't match reality (e.g. spec says "the powders table has a single `name` column" but the table also has a `display_label` column).
- A change the spec specifies would break an unrelated test that the spec didn't anticipate.
- A user-data migration risk emerges (relevant pre-launch is low-stakes, but post-launch will be).
- A discovered bug is in a code path the group's changes touch but the spec didn't mention.
- An obvious follow-up cleanup is sitting right next to the group's work but is out of scope.
- A security or privacy concern surfaces.

A red flag does NOT mean stop the phase. It means **surface it, finish the group's defined work, and let the operator + chat-Claude decide whether to absorb it into the current phase, defer it to the next phase, or open a separate bug ticket.**

### 5.5 What doesn't count as a red flag

- "I had to read three files to understand X" — that's just the cost of doing the work.
- "The spec was a bit terse here" — note it in the summary but it's not a flag.
- "I could see a tangentially-related improvement" — that's Phase N+1 queue material, not a flag for THIS group.
- "This was harder than expected" — neutral observation.

The point of the red-flag channel is signal, not chatter. Use it for things the operator + chat-Claude genuinely need to act on. Sub-flag observations belong in NOTES or DISCUSSION POINTS.

---

## 6. Communication norms

### 6.1 Operator → chat-Claude

Carries:
- Phase results from Claude Code (relayed verbatim or summarized).
- Design decisions ("go with option B").
- New requirements or scope changes.
- Uploaded files (code, screenshots, error messages).
- Questions about prior decisions.

The operator does not need to format these messages — natural prose is fine. Chat-Claude is responsible for asking follow-ups when a request is unclear.

### 6.2 Chat-Claude → operator

Carries:
- Audit findings (bad code, bad designs, hardcoded items, fragile patterns).
- Design proposals (with rationale).
- Options when there's a real fork.
- Spec drafts.
- Final spec + docs-target.

Chat-Claude **avoids** asking the operator to repeat themselves. If the operator's prior message has the answer, use it.

Chat-Claude **does not** push back endlessly. Once the operator has made a call, the spec reflects the call — even if chat-Claude would have made a different call. Reasoned disagreement gets one round; after that, the operator's decision stands.

### 6.3 Operator → Claude Code

Carries:
- The phase spec (.md file).
- Per-group go-ahead confirmations.
- Adjudication on questions Claude Code raised.

The hand-off is via the .md file. The operator does NOT re-explain the spec in chat-Claude-Code conversation — the spec is the source of truth. If Claude Code asks "but what about X?" and X is covered in the spec, the operator answers with "see § N of the spec."

### 6.4 Claude Code → operator

Carries:
- Per-group reports (structured format above).
- End-of-phase report.
- Red flags.
- Targeted questions when the spec is genuinely ambiguous.

Claude Code **does not** generate prose ramblings. The report format exists because structured output is faster to read and easier to relay back to chat-Claude.

Claude Code **does not** silently make design calls. If the spec is ambiguous on a point, halt + ask. If the spec is clear, follow it even if it seems weird — the spec captures decisions the operator already made.

### 6.5 Operator → chat-Claude (return loop)

Closes a phase. Carries:
- The end-of-phase report (or a summary).
- Any red flags + surprises.
- Operator decisions on those red flags.
- Triggers writing the next phase's spec.

---

## 7. When NOT to write the next phase yet

Chat-Claude does NOT pre-write Phase N+1 specs. Reasons:

1. **Phase N can change Phase N+1's baseline.** Test counts shift. Analyze counts shift. Schema version increments. Files rename. A pre-written Phase N+1 baseline is stale on arrival.
2. **Phase N can surface bugs.** Bugs that should land in Phase N+1's pre-flight don't exist in a Phase N+1 spec written before Phase N ran.
3. **Phase N can change priorities.** A bad surprise in Phase N might bump a Phase N+2 item to Phase N+1.
4. **Pre-writing creates premature commitment.** A 1,500-line Phase N+1 spec is hard to throw away when Phase N reveals a better path. Holding the spec until Phase N closes keeps the architecture pliable.

When Phase N is in flight, chat-Claude:

- Holds Phase N+1 design ideas as a queue (with one-line summaries).
- Pre-thinks open questions so the next planning session is fast.
- Does NOT write the full Phase N+1 spec until the operator returns with Phase N's close-out.

The cost of waiting is small (one chat session of latency between phases). The cost of writing prematurely is large (stale specs, wasted operator review time, awkward bug-fix integration).

---

## 8. What chat-Claude does NOT do

- Push commits to the repo.
- Modify files in the repo.
- Run `flutter analyze` or `flutter test` (chat-Claude has no Flutter runtime).
- Make design decisions the operator should make.
- Write Phase N+1 before Phase N closes (§ 7).
- Generate placeholder code for "future phases" without an operator-confirmed scope.
- Bypass the audit cycle when unknown territory calls for it.
- Re-explain a spec in chat that's already covered in the .md file — point to the section instead.

---

## 9. What Claude Code does NOT do

- Make design calls. If a design call is needed, halt + ask.
- Batch unrelated changes into a single group's commit.
- Silently add "while I'm in here" cleanups. Surface as a red flag.
- Push commits with failing tests.
- Push commits with new analyze issues (unless the spec explicitly expects them).
- Skip the per-group report format.
- Skip the halt at group boundaries.
- Argue with the spec. If the spec is wrong, halt + ask the operator to clarify.

---

## 10. Doc-as-source-of-truth

When code and docs disagree, **the docs are the target and the code is the work item.**

LoadOut is pre-launch. There are no users to migrate, no contracts to honor, no deprecation cycle. Locking documentation to current implementation creates accidental commitment to designs that were chosen under uncertainty and are now wrong. When a cleaner design emerges, the docs update first; the code follows in a focused migration phase.

Concretely:

- Specs describe the **target state**, not the current state. "What the code SHOULD be after this group" — not "what the code currently does."
- Doc updates are typically **part of the same phase** that makes the code change. Group 1 sometimes does the docs baseline sync; the final group does the docs final pass.
- "We can't change that, we already shipped it" doesn't apply pre-launch.

This principle applies to all four facet docs (Engineering, Marketing, Ballistics, UI) as well as LAUNCH_CHECKLIST.md and PRIVACY_POLICY.md.

---

## 11. Scope discipline (one chat, one focus area)

Each chat session has a focus area. Other areas are out of scope for that chat.

Current scope conventions (subject to change as the project evolves):

| Chat focus | In scope | Out of scope |
|---|---|---|
| Engineering — Recipes | Recipes surface (`lib/screens/recipes/`), related repositories, Engineering.md § 19 | Ballistics, Range Day, UI.md edits beyond mentioning surface implications |
| UI | Screen layouts, picker behavior, scene painter, UI.md | Engineering details, ballistics math, marketing copy |
| Ballistics | Solver code, drag tables, atmospheric corrections, Ballistics.md | UI surfaces, marketing claims, scene painter |
| Marketing | Voice, brand promises, App Store / Play Store copy, Marketing.md | Implementation details, math correctness, schema |

When a phase crosses areas — for example, a new Pro feature involves engineering plumbing AND UI changes AND a marketing line — the phase happens in **multiple chats**, one per area. The chats reference each other via notes in the spec ("see UI chat for screen-level changes").

Scope discipline prevents specs from sprawling into "while we're in here." A Recipes Engineering spec doesn't touch ballistics math, even if a tangential ballistics concern surfaces during analysis.

---

## 12. Hard fences

Some files require explicit operator sign-off before touching, regardless of phase. Listed in Engineering.md § 12. Summary:

- `lib/services/revenue_cat_config.dart`, `onedrive_config.dart`, `ai_smart_import_config.dart`, `Info.plist` — sensitive config.
- `lib/services/backup_crypto.dart`, `purchases_service.dart`, `auth_service.dart`, `biometric_service.dart`, `cloud_backup_service.dart` — sensitive services.
- `lib/services/ballistics/solver.dart`, `hit_probability_service.dart`, `hit_probability_map_service.dart` — math-audit boundary.
- `_RealisticTargetPainter` in `lib/screens/range_day/widgets/target_plot.dart` — frozen until Phase 11+.

If a spec asks Claude Code to touch a hard-fenced file, Claude Code halts and confirms with the operator before proceeding. Specs that legitimately need to touch these files include the fence-clearance in their pre-flight.

---

## 13. Reference files (this workflow)

- `CLAUDE.md` — top-level project router (read first for product context).
- `Engineering.md` — engineering reference (HARD-FENCE list in § 12; workflow conventions in § 13).
- `DEVELOPMENT.md` — this file.
- `LAUNCH_CHECKLIST.md` — pre-launch task tracker.
- `LOADOUT_PROJECT_HANDOFF.md` — session-restore doc; live across sessions for institutional memory.
- Phase specs (in `/mnt/user-data/outputs/` during a chat, or saved by the operator into a phase-archive folder once executed).
- Per-phase Engineering.md targets (operator chooses where these live — typically replacing the in-repo Engineering.md at the end of the phase's docs-final group).

---

## 14. Cheat sheet (for a returning Claude session)

If you are chat-Claude opening a fresh session:

1. Read CLAUDE.md (product context).
2. Read this file (process context).
3. Read the relevant facet doc (Engineering.md / Marketing.md / Ballistics.md / UI.md).
4. Wait for the operator to set the chat scope. Don't assume.
5. When the operator describes a problem, your output is **analysis + design + spec**, not code.
6. Write specs as .md files in `/mnt/user-data/outputs/`. Present via `present_files`.
7. Do NOT write Phase N+1 until Phase N closes (§ 7).

If you are Claude Code receiving a spec:

1. Read CLAUDE.md (product context).
2. Read this file (process context).
3. Read the spec end-to-end before touching any file.
4. Read the files the spec's pre-flight tells you to read.
5. Confirm the baseline (`flutter analyze`, `flutter test`).
6. Execute Group 1. Commit. Push. Report. **Halt.**
7. Wait for operator confirmation. Execute Group 2. Same pattern.
8. After the final group, emit the end-of-phase report.
9. Do NOT design. Do NOT batch. Do NOT silently expand scope. Halt + ask if anything's ambiguous.

If you are the operator:

1. Open a chat, set the scope ("this chat is Engineering — Recipes").
2. Upload relevant files.
3. Iterate on design with chat-Claude until the spec is unambiguous.
4. Download the spec + docs-target from chat.
5. Hand the spec to Claude Code.
6. Per-group: read the report, confirm or pause, continue.
7. At end-of-phase: report results back to chat-Claude.
8. Iterate.

---

## 15. When to update this document

Update when:

- A new workflow convention emerges and survives two phases.
- A failure mode reveals a gap (e.g. "Claude Code drifted because the spec didn't explicitly forbid X" → add to § 9).
- A new role or chat-scope convention stabilizes.
- The phase / group structure changes meaningfully (e.g. introducing sub-phases or parallel groups).

Don't update for:

- One-time exceptions.
- Aspirational changes the workflow hasn't actually adopted.
- Stylistic preferences.

This document tracks **what we actually do**, not what we wish we did. If the practice diverges from this doc, the practice wins until the doc updates to match.
