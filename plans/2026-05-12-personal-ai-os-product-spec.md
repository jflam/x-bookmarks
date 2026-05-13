# Personal AI Operating System Product Spec

Date: 2026-05-12

## Goal

Design a local-first personal AI operating system that helps the user learn,
make connections, manage private source material, model financial futures, and
launch agentic work sessions from rich context.

This is broader than the X bookmarks wiki. The X bookmark system is one input
and one knowledge surface inside a larger personal software estate.

The system should be malleable, simple, and agent-extensible because its final
shape is not knowable in advance.

## Core Thesis

Agentic coding makes it possible for ordinary people to have something that used
to require a billionaire-scale personal engineering team: private, bespoke,
continuously maintained software that adapts to one person's life.

The reference story is Paul Allen's personal entertainment system: an engineering
team maintained a private system across homes and yachts so he could request a
specific TV episode and have it routed to the screen in front of him. The modern
version is not just media. It is personal knowledge, finance, health, writing,
learning, life planning, and software automation maintained by agents.

The personal AI OS should be the control surface and memory layer for that
private software estate.

## Design Principles

### Malleable And Agent-Readable

Prefer artifacts that agents can read, edit, and reason about:

- Markdown for plans, manuals, knowledge pages, source notes, and review cards.
- JSON or YAML for explicit configuration and card metadata.
- SQLite for structured local state, telemetry, financial data, and due queues.
- Small scripts and CLIs over monoliths.
- Explicit schemas over implicit UI-only state.
- Reversible decisions and append-only logs where practical.

Avoid early commitment to a heavy platform, opaque database, or UI-only workflow.

### Local First

Private sources stay local by default:

- financial data;
- health data;
- scanned books;
- Kindle extracts;
- private notes;
- telemetry;
- agent traces;
- source-derived review cards.

External APIs can be used intentionally, but the system should preserve local
copies, provenance, and user control.

### Finite Review, Not Infinite Engagement

The system should not become an endless algorithmic feed.

It should generate bounded review queues:

- due spaced-repetition items;
- new source cards;
- dormant but important threads;
- speculative relationship cards;
- active-investigation updates;
- follow-up source tasks.

The feed ends. Reaching the bottom is a feature.

### Launch With Context, Not Workflow

Relationship cards should not force a fixed action. The primary action is:

```text
Open chat with this card as context.
```

Cards should carry enough source-backed context for an agentic session to start
without the user re-explaining the source, hypothesis, related pages, open
questions, and prior feedback. Optional shortcuts can come later, but the user
is good at prompting and should not be constrained by rigid UI workflows.

### Draft Freely, Mutate Cautiously, Decide Never

Agents may maintain knowledge and review surfaces. Agents may prepare options,
workpapers, draft scenarios, candidate rules, and source-backed syntheses.

Agents must not silently make financial, tax, health, legal, publishing, or
external-action decisions.

## System Architecture

```text
Sources
  -> Local Stores
  -> Knowledge Layer
  -> Review / Feed Layer
  -> Agent Launch Layer
  -> Domain Apps
```

### Sources

Initial and expected sources:

- X bookmarks and raw post exports.
- Scanned print books.
- Kindle books and purchased ebooks where the workflow is private and personal.
- Papers and long-form web sources.
- FinanceBoss data and scenarios.
- Future health data sources.
- Private notes and conversations.
- Agent session outputs.

### Local Stores

Initial local stores:

- `~/src/brain2/X Bookmarks/raw/...` for raw source files.
- `~/src/brain2/X Bookmarks/wiki/...` for compiled knowledge.
- `~/src/financeboss/data/financeboss.sqlite` for personal finance state.
- Future `raw/books/...` or equivalent for book text and chapter OCR.
- Future local event store for telemetry.

### Knowledge Layer

The knowledge layer should compile source material into:

- concepts;
- tools;
- projects;
- maps;
- syntheses;
- questions;
- source-backed study guides;
- active investigations;
- personal OS steering docs;
- relationship cards.

The X bookmarks wiki already implements much of this pattern.

### Review And Feed Layer

The review layer should combine:

- spaced repetition;
- relationship radar;
- source follow-up;
- dormant topic resurfacing;
- active investigations;
- finite daily or weekly review queues.

Feed card types:

- `spaced_review`: a source-backed recall item is due.
- `relationship_radar`: speculative connection across topics.
- `source_follow_up`: a primary source, paper, repo, or book chapter should be collected.
- `decision_support`: relevant to finance, retirement, health, writing, or life planning.
- `dormant_thread`: important topic not reviewed recently.
- `new_signal`: new source that changes or complicates a page.

### Agent Launch Layer

Any source, note, chart, review card, or relationship card should be able to
launch an open-ended chat/agent session with a structured context bundle.

This is analogous to clicking Grok on a tweet, but more powerful because the
agent receives:

- the triggering source;
- related wiki pages;
- current hypotheses;
- prior user feedback;
- active investigations;
- relevant local project context;
- provenance and caveats.

### Domain Apps

Initial domain apps:

- X bookmarks wiki.
- FinanceBoss.
- Future book/paper ingestion pipeline.
- Future relationship feed UI.
- Future writing studio.
- Future health dashboard.

## Current Attention Areas

The system should track current attention, not pretend to predict future
interests. Interests are expected to drift. The system should preserve important
threads even when the user's recent signal gets sparse.

Current high-priority areas:

- Agentic coding and surrounding workflows.
- Self-improving systems, optimization frameworks, and DSPy-like approaches.
- Inference stack economics and system architecture.
- CPU, storage, networking, and downstream compute impact from inference growth.
- Portfolio design and retirement planning.
- Tax-efficient decumulation across taxable, IRA, spouse IRA, RRSP, and other assets.
- AI in pharma, biomedicine, and autonomous labs as an emerging interest.
- Life transition, retirement identity, Stoicism, Sahil Bloom, David Brooks, and life design.
- Writing as a near-future focus area.
- Learning and memory retention.

## Personal Software Estate

The system should model the broader idea of personal software estates:

```text
private context + local data + agentic coding + review loops
  -> continuously evolving personal software
```

Expected domains:

- knowledge and learning;
- finance;
- health;
- writing;
- retirement and life design;
- personal dashboards;
- local automations.

This thesis has an infrastructure implication: if many people maintain standing
private software teams, compute and storage demand may rise sharply. Demand may
not be limited to GPUs. Agentic workloads use CPUs, browsers, sandboxes, file IO,
retrieval, parsing, logs, tests, storage, and orchestration.

## Relationship Feed

### Purpose

Surface speculative cross-topic relationships the user might not have noticed.

High-confidence links are useful but less valuable by themselves because the user
often notices them already. The feed should emphasize high-novelty,
moderate-evidence relationships that are tied to active projects or decisions.

### Ranking Signals

Suggested ranking dimensions:

- Interest score: recent and repeated attention.
- Dormancy score: important thread not reviewed recently.
- Novelty score: likely new connection.
- Evidence score: source quality and number of supporting artifacts.
- Actionability score: relevance to a decision, project, model, or review.
- Feedback score: explicit and implicit user signals.

### Feedback Semantics

Signal hierarchy:

- Strong positive: launches chat, saves, edits related page, promotes, marks useful.
- Weak positive: opens, dwells, follows links, revisits.
- Neutral: shown once and ignored.
- Weak negative: shown multiple times and skipped.
- Strong negative: explicit show less, wrong, too obvious, not relevant.

Silence is ambiguous. The system should not overlearn from one skipped card.
Explicit feedback should dominate weak telemetry.

### Example Card Shape

```markdown
## Inference Stack <-> Retirement Portfolio Risk

### Why Surfaced

You have an active inference explosion hypothesis and are building FinanceBoss
for retirement and portfolio modeling.

### Hypothesis

Inference demand may create a broader hardware cycle than the market currently
prices, including CPUs, memory, storage, networking, and orchestration
infrastructure.

### Sources

- [[concepts/ai-infrastructure-bottlenecks]]
- [[concepts/inference-compute-investment-thesis]]
- [[projects/financeboss]]

### Agent Context

Use this card as context. Explore whether the triggering source strengthens,
weakens, or complicates the inference explosion thesis. Identify evidence that
would change the conclusion. If relevant, propose a FinanceBoss modeling task.

### Feedback

- useful:
- wrong:
- too obvious:
- too speculative:
- needs sources:
- show more like this:
- show less like this:
```

## Spaced Repetition

### Purpose

Spaced repetition should help the user remember what they read and learn.

Good targets:

- factual details;
- definitions;
- named frameworks;
- mechanisms;
- source summaries;
- important distinctions;
- mental models;
- arguments and counterarguments;
- book chapter takeaways;
- paper claims, methods, and limitations;
- concrete relationships between ideas.

Poor targets:

- broad aspirations;
- vague life hypotheses;
- generic "think about retirement" prompts;
- unsupported synthesis;
- trivia or decorative anecdotes.

### Book Review Cards

For books and chapters, generate a few high-value cards per chapter, not many
exhaustive cards.

Selection criteria:

- Is this a named concept or framework?
- Would forgetting this weaken understanding of the book?
- Does it connect to an active investigation?
- Is it an exercise or practice the user may actually use?
- Does it clarify a distinction the user is likely to blur?
- Would it help the user explain the book to someone else?
- Does it update or challenge an existing mental model?

Ordinary chapters should usually produce 3-7 high-value cards. Dense technical
chapters or papers may produce more.

### Card Provenance

Cards should cite chapter-level sources, not merely book-level sources.

The card should answer:

- What am I supposed to remember?
- Where did this come from?
- What context should an agent load if I ask about it?
- Is this faithful to the source or personal synthesis?

## Book And Paper Ingestion

### Source Policy

The user intends to scan owned print books and ingest purchased ebooks for
private personal use. The system should treat book text as private source
material and should not publish or export full book text.

Conservative operating rules:

- Keep raw scans and OCR private.
- Do not publish full book text.
- Generate private notes, study guides, and review cards.
- Use short excerpts only where needed.
- Preserve book, chapter, and location provenance.

### Pipeline

```text
owned book / paper
  -> scan or import
  -> OCR / text extraction
  -> raw source store
  -> chapter segmentation
  -> faithful study guide
  -> aggressive personal synthesis
  -> spaced repetition cards
  -> relationship feed entries
```

### Dual Outputs

Every substantial book should produce two parallel artifacts:

1. Faithful study guide:
   - chapter summaries;
   - key claims;
   - definitions and frameworks;
   - important examples;
   - exercises and practices;
   - high-value review cards;
   - "what to remember" sections.

2. Aggressive personal synthesis:
   - links to current interests;
   - relationship cards;
   - implications for FinanceBoss, writing, retirement, health, learning, and agentic coding;
   - contradictions with other sources;
   - open questions;
   - suggested experiments.

### Designing Your Life

The first known book target is `Designing Your Life` by Bill Burnett and Dave
Evans.

Likely concepts to extract:

- wayfinding;
- Good Time Journal;
- Odyssey Plans;
- prototyping conversations;
- prototyping experiences;
- dysfunctional beliefs and reframes;
- gravity problems;
- workview and lifeview coherence.

Likely personal synthesis connections:

- retirement transition;
- life design and identity after work;
- FinanceBoss scenario planning;
- writing as future practice;
- learning and personal operating system design.

## FinanceBoss Integration

FinanceBoss is a local personal finance datastore and analysis app built around
Tiller-powered Google Sheets.

Current intended flow:

```text
Tiller -> Google Sheet -> local importer -> SQLite -> AI/query layer -> local web UI
```

Tiller handles bank and brokerage aggregation. FinanceBoss imports the sheet into
local SQLite for querying, classification, dashboards, AI-assisted analysis, and
future modeling.

### Product Boundary

FinanceBoss should do the grunt work. The CPA or other advisor should do
accountable professional judgment.

Principle:

```text
Use agents and local software to collect data, reconcile accounts, classify
transactions, model scenarios, prepare questions, and generate draft workpapers.
Use credentialed professionals for decisions where legal/accounting liability,
regulatory interpretation, or high-stakes judgment matters.
```

### FinanceBoss Future Modules

- Portfolio design.
- Retirement planning.
- Tax-efficient retirement and decumulation.
- CPA workpaper preparation.
- Sounding-board analysis.
- Investment thesis tracking.
- Scenario modeling.
- Data provenance and stale-value warnings.

### First-Class Account And Asset Pools

FinanceBoss should model:

- taxable brokerage;
- cash and money market;
- traditional IRA;
- spouse IRA;
- Canadian RRSP;
- Microsoft stock and RSUs;
- home equity;
- vehicles;
- Social Security;
- CPP / OAS;
- pensions or pension-like income if applicable.

The user does not currently have a Roth IRA. Roth should be tracked as a planning
question rather than an account entity:

- Should the user add Roth exposure?
- Are backdoor Roth contributions relevant?
- Are Roth conversions useful before RMD years?
- How do Roth moves interact with RRSP, taxable gains, health insurance, Medicare,
  and CPA advice?

### Retirement And Portfolio Goals

FinanceBoss should help maintain an evidence-based retirement and portfolio
operating plan:

- preserve financial independence;
- avoid missing too much upside;
- de-risk intelligently;
- model drawdown order;
- prepare tax-efficient plans;
- prepare CPA workpapers;
- test investment theses;
- surface assumptions and sensitivity.

The user believes they may already have the financial means to retire. The
problem is preserving, expanding, and intelligently de-risking that position.

### Decumulation Questions

Core question:

```text
How should taxable accounts, IRA accounts, spouse IRA, Canadian RRSP, Social
Security, CPP/OAS, and other pools be drawn down over time?
```

Distinguish:

- sequence-of-returns risk: bad early retirement returns combined with withdrawals;
- tax-efficient decumulation: which account to draw from, when, and why.

### CPP / OAS Planning

CPP should become a retirement input, sourced from the user's Service Canada
Statement of Contributions.

Fields:

- `cpp_estimated_at_60`
- `cpp_estimated_at_65`
- `cpp_estimated_at_70`
- `cpp_start_age`
- `cpp_tax_treatment`
- `source`
- `needs_cpa_review`

Current understanding to verify with CPA:

- CPP eligibility generally depends on at least one valid CPP contribution and
  age 60 or older.
- My Service Canada Account can provide contribution history and benefit estimates.
- For a US tax resident, CPP/QPP/OAS are generally treated under treaty rules as
  US Social Security-equivalent benefits rather than ordinary Canadian pension
  income, but this requires CPA verification in the user's actual situation.

### Investment Thesis Tracking

The inference explosion thesis should be an active investment investigation.

Questions:

- Is the market underpricing AMD and Intel relative to inference demand?
- How much downstream compute is required beyond GPUs?
- What happens to CPU, memory, storage, networking, and orchestration demand?
- What portfolio exposure currently maps to this thesis?
- What evidence would falsify or weaken it?
- What sizing is compatible with retirement risk?

FinanceBoss should eventually connect positions and asset classes to theses:

- inference compute;
- AI infrastructure;
- pharma/biomedicine AI;
- cloud providers;
- power and utilities;
- memory and HBM;
- networking;
- storage;
- semiconductor equipment.

## Health Dashboard

The health module is not yet specified in code, but it belongs in the personal
OS architecture.

Future scope:

- labs;
- biomarkers;
- medications and supplements;
- sleep;
- workouts;
- health records;
- doctor-facing summaries;
- primary literature;
- AI pharma and biomedicine source tracking.

Agents may summarize and prepare questions. Agents must not make final medical
decisions or mutate health source records without explicit approval.

## Writing Studio

Writing is expected to become a larger part of the user's future.

The writing module should help turn:

- bookmarks;
- book notes;
- papers;
- relationship cards;
- life reflections;
- FinanceBoss scenarios;
- active investigations;

into:

- outlines;
- essays;
- argument maps;
- memos;
- drafts;
- revision queues.

Writing should be a first-class output of the personal OS, not a side effect.

## Telemetry

Telemetry is acceptable if it is local, inspectable, editable/deletable, and used
to improve review quality rather than maximize engagement.

Events to capture:

- page opened;
- source card opened;
- dwell time bucket;
- relationship card shown;
- relationship card opened;
- chat launched from card;
- card skipped;
- card deferred;
- card marked useful or not useful;
- show more / show less;
- search query;
- source imported;
- spaced-repetition card reviewed;
- spaced-repetition card failed or passed;
- wiki page manually edited;
- FinanceBoss scenario opened or rerun.

Possible v1 store:

```text
data/personal-os/events.jsonl
```

Possible structured store:

```sql
personal_os_events(
  id,
  timestamp,
  event_type,
  object_type,
  object_id,
  metadata_json
)
```

JSONL is more inspectable. SQLite is better for ranking and queries. The first
implementation should choose the simplest store that supports feed generation.

## Autonomy Model

Agents may act directly:

- ingest sources into raw areas;
- draft and update wiki pages with citations;
- add relationship cards;
- add candidate spaced-repetition cards;
- update maps, indexes, and logs;
- generate study guides from books and papers;
- draft product specs and plans;
- create FinanceBoss scenario drafts;
- create proposed transaction rules;
- generate CPA/advisor question lists;
- run read-only local analysis;
- produce "why surfaced" explanations.

Agents must propose for approval:

- moving or deleting durable wiki pages;
- changing source-of-truth financial data;
- accepting FinanceBoss classification rules;
- changing account/entity metadata;
- making tax assumptions that affect official workpapers;
- marking a financial scenario as recommended;
- editing health records, medication lists, labs, or doctor-facing summaries;
- scheduling or sending communications;
- publishing or exporting private notes or book text;
- changing telemetry policy;
- suppressing an entire topic long term;
- converting speculative relationship cards into durable claims.

Agents must not do without explicit instruction:

- make trades;
- file taxes;
- send data to external services when local-only was expected;
- share copyrighted book text;
- give final medical, tax, or legal advice;
- delete raw source material;
- irreversibly mutate financial or health source records.

## V1 Product Shape

V1 should not attempt to build the entire OS. It should create the substrate for
agentic evolution.

Recommended V1:

1. Planning artifacts in `x-bookmarks/plans`.
2. Durable wiki steering pages when ready.
3. Relationship card Markdown schema.
4. Finite relationship feed generated as Markdown.
5. Local telemetry event schema.
6. Book ingestion folder/schema proposal.
7. FinanceBoss project page and integration note.
8. Source-backed spaced repetition schema.

## Open Questions

- Should relationship feed generation live in `x-bookmarks`, the Obsidian vault,
  or a new personal OS repo?
- Should telemetry start as JSONL or SQLite?
- Should book ingestion operate directly on PDFs or on chapter-extracted Markdown?
- How should book OCR quality be represented?
- How should relationship cards be launched into agent sessions from Obsidian?
- Should there be an Obsidian plugin, a local web app, or both?
- How should FinanceBoss expose scenario bundles to the relationship feed?
- What is the minimum useful health dashboard source set?
- How should spaced repetition scheduling be implemented?
- How should explicit feedback be stored so future agents use it consistently?

## Expected Near-Term Artifacts

- `plans/2026-05-12-personal-ai-os-product-spec.md`
- `plans/2026-05-12-personal-ai-os-agent-operating-manual.md`
- Future `wiki/projects/personal-ai-operating-system.md`
- Future `wiki/maps/personal-ai-operating-system.md`
- Future `wiki/concepts/personal-software-estates.md`
- Future `wiki/concepts/finite-personal-research-feed.md`
- Future `wiki/concepts/source-backed-spaced-repetition.md`
- Future `wiki/concepts/book-ingestion-for-personal-knowledge.md`
- Future `wiki/projects/financeboss.md`

