# Question Bank

Use this bank selectively after inspecting available evidence. Ask only questions that change implementation or acceptance.

## Core questions for every task

- Who performs the action, and what outcome should they observe?
- What is wrong or impossible today? Provide a concrete example.
- What is the smallest successful result?
- What is explicitly outside this task?
- Which existing behavior must remain unchanged?
- What evidence will make the author accept the work?
- Are there deadline, rollout, compatibility, or approval constraints?

## Frontend and UI

### Source of truth

- Is there an exact design, screenshot, prototype, or existing component to match?
- Which parts are fixed and which may be interpreted?
- Is copy final? Who owns missing copy, icons, illustrations, and assets?

### Behavior and states

- What starts the flow and where does the user land afterward?
- Define default, hover, focus, active, disabled, loading, empty, success, error, partial-data, offline, and permission-denied states that apply.
- What happens on double click, repeated submit, refresh, back navigation, or an expired session?
- Which validation is client-side, server-side, or both? When and where is each message shown?

### Layout and accessibility

- Which viewport widths and devices are supported? What reflows, hides, scrolls, or becomes fixed?
- What are keyboard order, focus behavior, escape behavior, labels, announcements, and contrast expectations?
- Are animation and reduced-motion behavior defined?
- Are locale, long text, pluralization, RTL, date/time zone, and number formats relevant?

### Integration

- Which existing components, design tokens, routes, stores, analytics events, and feature flags must be reused?
- What is the exact request/response contract and how should stale, partial, or failed data appear?
- Is pixel comparison or a browser screenshot required? At which viewports?

## Backend, API, and integrations

### Contract

- Who calls the interface, with what authentication and authorization?
- Define method/topic, path, headers, parameters, payload schema, required/optional/null semantics, response schema, status/error codes, and examples.
- What are pagination, filtering, sorting, rate limits, timeouts, retries, and idempotency rules?
- Is the change backward compatible? Which clients or versions must continue to work?

### Domain and data

- What invariants and state transitions must hold?
- What is the source of truth and transaction boundary?
- How are duplicates, concurrent writes, ordering, partial failure, and eventual consistency handled?
- What data is sensitive? What must be encrypted, redacted, retained, or deleted?
- Is a schema or data migration needed? Define backfill, batching, validation, rollback, and mixed-version behavior.

### Operations

- What latency, throughput, availability, and size limits apply?
- Which structured logs, metrics, traces, dashboards, and alerts prove health?
- Which external sandbox, mocks, credentials, quotas, or webhook verification are needed?
- What happens when the dependency is slow, unavailable, duplicated, or returns malformed data?

## Bugs

- What are the exact reproduction steps, environment, inputs, account/role, and frequency?
- What is actual behavior versus expected behavior?
- What is the earliest known good version and first known bad version?
- Are logs, screenshots, traces, request IDs, failing tests, or suspect changes available?
- What is the blast radius and severity? Is there data loss, security impact, or a safe workaround?
- Must the fix repair existing bad data or only prevent recurrence?
- Which regression test fails before the fix and passes after it?

## Refactors

- Which observable behavior and public contracts must remain identical?
- What measurable problem is being solved: complexity, duplication, performance, operability, or upgradeability?
- Which modules may change and which are protected?
- Is staged migration required? Can old and new paths coexist?
- What characterization tests protect behavior before structural changes?
- What objective condition proves the refactor complete?

## Infrastructure and delivery

- Which environments, regions, accounts, and tenants are affected?
- What are the desired state, current state, and drift policy?
- What secrets, identities, network boundaries, and least-privilege rules apply?
- What are capacity, cost, backup, restore, disaster recovery, and maintenance-window constraints?
- Is rollout canary, phased, blue/green, or immediate? Define rollback trigger and procedure.
- Which health checks and post-deploy smoke tests are required?

## Research or spike

- What decision will the research enable?
- Which alternatives and constraints must be evaluated?
- What evidence is acceptable: prototype, benchmark, source review, or cost estimate?
- What is the time box and stopping condition?
- What deliverable and recommendation format are required?

