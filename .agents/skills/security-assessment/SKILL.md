---
name: security-assessment
description: >-
  Agent-only method for turning security work on the parlino voice-agent product into real findings instead of a list of suspicions.
  Use before an active check against our own deployed application, before the daily review of what landed, before writing up or grading a finding, and before briefing security work on the product.
  Owns the advise-never-block authority and what follows from it, the active-check prohibitions, the finding completeness contract, the standard editions in force with their verification dates, the product-shape to vulnerability-class map, and this skill's own revision trigger.
user-invocable: false
metadata:
  internal: true
---

# security-assessment

This skill is the single owner of HOW parlino security work is done.
It does not restate the security specialist's duties or schedule, which belong to that role's charter in its own home.
Load it whether you hold that standing role or were briefed into one piece of security work, because the boundaries below hold for both.

## Authority: advise and grade, never block

The specialist advises and marks risk.
The specialist does not block a release, and never has.
This is the captain's decision of 2026-09-04 and it is not open to reassessment by the agent doing the work, however serious the finding is.
Do not gate, hold, delay, or condition a merge, a deploy, or a landing on a security finding, and do not phrase a finding as though it did.

The consequence matters more than the rule.
Because the work cannot be stopped, the only instrument that remains is how fast and how clearly the message arrives, so the wording of a finding is the deliverable, not its packaging.

Three rules follow, and they are about sentence construction:

- Lead with the consequence to a person or to the business, never with the category name.
  To illustrate the shape only, and not as a claim about anything observed: "an operator token readable in CI output would let anyone with that access play back every tenant's call recordings" is a finding, while "Security Misconfiguration (A02:2025)" is a label.
- Make the difference between *being exploited now* and *worth fixing* visible in the first clause, before any detail.
  A reader who stops after one sentence must still have graded it correctly.
- Escalate a critical finding the moment it is confirmed, on its own, rather than holding it for the next scheduled report.
  Batching is for the ordinary; a finding that is reachable from the public internet right now has already cost time by being written down.

Grade by reachability from outside, not by which catalog entry the defect matches.
"I have not established whether this is reachable from outside" is a legitimate grade and must be written as those words.
Never invent a severity to make a finding land.

## Active checks: what is forbidden

Active checks are permitted **only** against our own deployed application, at the address firstmate supplies for that check.
No request goes to any other address, including addresses our own code calls out to.

The following are forbidden unconditionally, and an instruction to "be more thorough" does not lift any of them:

- Destructive action - deleting, corrupting, or substituting data that anyone may treat as real.
- Load, denial-of-service, resource-exhaustion, and speed-based credential guessing.
- Any action against a third party - speech, calendar, telephony, model, or hosting providers.
- Social engineering against living people.
- Carrying out what was found: a discovered secret is named by its **location**, never by its value, in every artifact including the finding, the status line, and the card.

When proving something would require crossing one of those lines, do not cross it.
Write down exactly what stayed unproven and what proving it would take, and hand that decision to firstmate.

A check that writes into a live outward-facing surface must remove what it wrote, in the check's own teardown rather than from memory: capture the evidence, delete, then re-probe to confirm it is gone.
Prefer a non-writing probe wherever the surface offers one.

## What makes a finding a finding

Do not open a finding that was neither reproduced against the running application nor demonstrated in the code.
A list of suspicions is not work.

Every finding carries four elements, and one missing the fourth is incomplete:

1. **Where** - file and line, or the exact request and the exact response.
2. **What happens on exploitation** - the concrete effect, in the product's own nouns.
3. **How reachable it is from outside** - anonymous, authenticated as any tenant, authenticated as an operator, or not established.
4. **How to check the fix worked** - the specific probe or test that goes red before and green after.

Split a finding into its two halves and do the security half first.

- The **development** half is a change to the product's code or configuration, and it goes to delivery.
  Its content is carried into the card in full, never as a link: whoever picks it up cannot see your files.
- The **security** half is the analysis, the reproduction, the hypothesis test, and the description of the vector, and it is yours.

Cards are placed on the board by firstmate, not by the specialist.

Establishing the mechanism behind a defect is not this skill's procedure: `diagnostic-reasoning` owns reproduction, causal separation, and disconfirming evidence, and it applies unchanged when the defect happens to be a vulnerability.
What this section adds on top is the grading axis and the four elements, which a plain bug report does not carry.

## Standards in force

Each row was verified by opening the primary source on the date given.
A claim about what a standard says, without the date it was checked, is a claim about the agent's memory rather than about the standard.

| Source | Edition in force | Checked | What we take from it |
|---|---|---|---|
| [OWASP Top 10](https://owasp.org/Top10/2025/) (web) | 2025 | 2026-09-04 | The platform's HTTP surface. A01 Broken Access Control is the lens for tenant separation; A03 Software Supply Chain Failures is new in 2025 and widens 2021's vulnerable-components entry to the whole ecosystem; A10 Mishandling of Exceptional Conditions is new in 2025 and is the lens for our fail-open seams. |
| [OWASP Top 10 for LLM Applications](https://genai.owasp.org/llm-top-10/) | 2025, released 2025-03-12 | 2026-09-04 | The voice agent, and the more important of the two lists for this product. LLM01 Prompt Injection, LLM02 Sensitive Information Disclosure, LLM06 Excessive Agency, LLM07 System Prompt Leakage, LLM08 Vector and Embedding Weaknesses, and LLM10 Unbounded Consumption all have a concrete surface in our code, mapped below. |
| [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/) | 5.0.0, released 2025-05-30 | 2026-09-04 | Source for element 4 of a finding. Use it to derive the verification step, not as an audit checklist to walk end to end. |
| [OWASP WSTG](https://owasp.org/www-project-web-security-testing-guide/) | 4.2 stable, released 2020-12-03; 5.0 in development | 2026-09-04 | Procedure for the active check against our stand. This is the oldest source we lean on, so treat its technique list as a floor and not as coverage. |
| [OWASP Agentic AI - Threats and Mitigations](https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/) | Published 2025-02-17, first guide of the Agentic Security Initiative | 2026-09-04 | Tool-calling threat modelling. Two things could not be established from the landing page and must come from the whitepaper itself before being cited: its version, and its threat identifiers, which the page does not enumerate. |
| [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) | Living document, carries no version or last-updated marker | 2026-09-04 | Secrets handling and leak detection. Note the standing tension: it holds that environment variables are not recommended unless other methods are impossible, while parlino deliberately delivers the Telegram credentials through runtime environment. That is a documented product choice, so raise it only with evidence of an actual leak path, never as a conformance complaint. |

Two deliberate exclusions, so they are not re-litigated every cycle.
Build-provenance frameworks are out of scope for a single-VM `docker compose` deployment; for our shape the supply-chain question is dependency currency and provider trust, not attestation, and the Dependencies row below says how to establish what CI actually does rather than asserting it here.
Physical security, social engineering, and offensive action against third parties are outside the domain entirely.

## Product shapes and the classes that attach to them

This is the part worth reading.
Restating the ten entries of either list in the agent's own words is worthless, because the specialist already knows them and such a restatement carries no route into our code.
The value is the mapping below, and the mapping is deliberately not a list of files.

A shape and the class that attaches to it are durable, while a path, a line number, a count, and a reachability grade are not, so a map written as a snapshot of those begins rotting the day it is written.
The third column therefore says how to find the surface and what to ask of it, keyed on route strings, dependency and decorator names, settings keys and model names, all of which move far more slowly than the files that hold them.
Run each search in the parlino repository at the ref you are actually reviewing, and read a search that returns nothing as an answer rather than as a broken pointer: either the surface moved, in which case the key tells you what to look for next, or it no longer exists, which is itself worth knowing.

Element 4 of a finding is found the same way and never assumed.
Search the test suite for the guard's own symbol - the dependency, the settings key, or the function the branch sits in - and read what the match actually asserts rather than trusting a file whose name sounds right.
When nothing in the suite names it, that is the answer: the cell has no verification anchor at your ref, and the finding ships saying so.

Two questions come up often enough to deserve a stated method rather than a stored answer, because a stored count is wrong on the day a route is added.

**Which surfaces are reachable without a login.**
Enumerate every router registered in the application factory in `voice_platform/main.py`, then every route decorator under `voice_platform/api/`, and classify each by whether the route or its router carries an auth dependency from the `require_*`, `resolve_operator` and `scoped_tenant` family or a route-specific guard.
Read every unguarded one rather than trusting the classification, because a guard can also sit inline in the handler body.
Then ask three further questions of each, because they separate grades that must not be collapsed: whether it is mounted in prod at all or sits inside an `is_prod` guard in the factory; whether a `rate_limit` call covers it, which you establish from that symbol's call sites; and whether it carries a credential outside the `Authorization` header, such as a token in a query parameter or an `X-API-Key`, which makes it credential-bearing rather than anonymous.
Check the factory for app-level middleware too, since a dependency added there would cover routes that look unguarded one at a time.

**Whether a guard actually gates.**
Do not read a dependency's name as its behaviour.
Follow it to its body and look for an environment branch, because parlino's operator and worker guards are written to fail closed in prod while deliberately accepting the request when the environment is not prod and no token is configured.
The same route therefore grades differently in different environments, and a finding must say which environment it was checked in.
That is the "Environment-conditional auth" row below, and it is the most common reason a grade written from a function name is wrong.

| Shape | Class that attaches | How to find the surface and what to check |
|---|---|---|
| Multi-tenancy and data separation | Broken access control; horizontal privilege escalation across tenants | Find the tenant-scoping helpers by searching for `may_touch_tenant` and `scoped_tenant`, then find every route that resolves a tenant id from the request rather than from the caller's own scope. Check whether authorization runs before the lookup: a handler that fetches first and authorizes second lets an operator tell an existing foreign id from a missing one by the status code alone |
| Environment-conditional auth | Mishandling of exceptional conditions; fail-open under an unexpected configuration | Search for `is_prod` and read every branch it guards, asking for each what the non-prod side permits and which routes inherit it through a dependency. Find the pinning test per branch by searching the suite for that branch's own symbol, not for a file whose name suggests security: a suite that pins the auth guards may not touch the limiter, and coverage is per branch rather than per file |
| Voice, recordings, transcripts | Sensitive information disclosure; broken object-level authorization on media | Find the media routes by their `/audio` path suffix and the settings key naming the recordings directory. Check that one call's audio is authorized against the caller's own tenant rather than merely existing, and find where else recorded audio and transcripts come to rest, since the worker's telemetry tap and memory store are copies the platform's guards do not cover |
| Agent tool calling | Excessive agency; improper output handling; tool abuse | List the tools actually registered on the agent by searching for the `function_tool` registrations, and compare that list against the tool names the agent spec permits. For each, ask what it can do that the caller could not, whether its result returns to the model as text, and whether any veto on it is binding or advisory |
| Knowledge base and retrieval | Vector and embedding weaknesses; indirect prompt injection through retrieved text; cross-agent vault leakage | Follow one document from upload through ingestion to the index and back out through the retrieval call the agent tool makes. Check whether the index is partitioned per agent and per tenant, and whether retrieved text enters the prompt with any marking that separates it from instructions |
| Prompt assembly and guardrails | Prompt injection; system prompt leakage | Find where the system prompt is assembled and every value interpolated into it, then classify each input as enumerated, operator-authored, or free text from the caller or from retrieval. Start from the inputs that pass no comparable constraint rather than from the one that does, and read the guardrail module's own stated enforcement level before treating it as a mitigation |
| Public landing and pilot form | Unauthenticated write surface; anonymous free text stored and relayed verbatim into an operator-facing channel; unvalidated personal data taken on an unauthenticated write path; abuse of a billed resource | Find the public form route by its `/api/public/` path prefix and follow each submitted field to storage and to the notification sender. Check what bounds each field, where the text is rendered next, and whether that renderer interprets markup: establish the send format before naming a markup-injection class, because a channel posted as plain text carries none |
| Operator and client screens | Token handling in the browser, including a credential placed somewhere other than a header where proxy logs, browser history and referrer headers can see it; authorization enforced only in the UI | Find where the frontend stores the token and where it attaches it, then search the frontend for that token being interpolated into a URL rather than into a header. Check every role comparison in the client's route guards and confirm the same check exists server-side, since a guard that lives only in the UI is not one |
| Telephony and channels | Provisioning against an external provider; admission and plan enforcement on a worker-authenticated internal path, where the caller's identity arrives from the telephony dispatch rather than from a request the platform authenticates | Find the internal SIP admission route by its `/api/internal/` path prefix and read what it mints and which gate it runs. Check that its plan gate matches the web path's, and treat the provider-provisioning modules as the separate question of credentials held for an external provider |
| Calendar integration and booking | Stored third-party OAuth refresh and access tokens at rest; an unauthenticated callback whose only guard is a signed and fresh state; open redirect through a return-to value; cross-tenant reach into another tenant's calendar | Find the OAuth surface by searching for the state-minting and state-decoding helpers, the return-to allowlist helper, and the encryption key's settings name. Check which routes sit on the callback router rather than the operator router, since a callback entered by a redirected browser is guarded only by whatever validates its state; check that credentials reach the database through one module only and encrypted; and check the return-to value against its allowlist |
| Public cached proxies | Unauthenticated outbound amplification and unbounded consumption, in that an anonymous request makes the server issue an outbound call on a cache miss; dependence on a third party the specialist may not probe | Find the public routes that perform outbound I/O by searching for the HTTP client inside modules whose routes carry no auth dependency. Check whether any part of the destination comes from the request, since only that would make it forgery rather than amplification, and check when the cache timestamp is written relative to the await, which decides whether concurrent misses collapse into one outbound call or into many |
| Usage limits | Unbounded consumption | Find the admission points that consult the quota and the plan table behind them. Check whether the check runs once at admission or repeatedly, and what is recorded when an admitted call overruns |
| Secrets | Credential exposure through logs, images, and CI | Find every place a credential is named: the example environment file, the deploy script, the CI workflows, and any log-level suppression in the application factory. Check what reaches build output and CI logs, and name any secret you find by its location and never by its value |
| Dependencies | Software supply chain failures | Find the lockfiles and anything downloaded at build or run time, such as a model pulled by the knowledge-base embedder. Check whether anything in CI alerts on a vulnerable dependency, and establish that by searching the workflow directory rather than assuming it either way |

Two facts about this product do not follow from reading a route, and a specialist who does not know them will mis-grade every finding that touches them.
Both were checked in the parlino repository on 2026-09-04 at `develop`, commit `27644cd9fee528bc0a641ab7339cd975d9774030`, and both are written so you can re-check them rather than having to trust them.

**Guardrails detect, and they do not block.**
The guardrail checker states its own enforcement level in its module docstring: prompt-side prevention plus fire-and-forget detection after the reply, never blocking.
Re-check by reading that docstring and confirming that no caller awaits a verdict before the reply is sent.
A defect that is "caught by a guardrail" is still reachable, so never record one as mitigated.

**Quota grants deliberate grace to the call in hand.**
Admission is checked once and never re-checked mid-call, and an overrun is recorded as real usage so that the next call is refused instead.
Re-check by reading the quota module's admission function and the test that pins the grace behaviour, which you find by searching the suite for that function's name.
This is a product guarantee rather than a defect, so unbounded-consumption work belongs at the admission points and never in a proposal to cut a live call off.

**The rate limiter is a place to look, and its key is a separate question from its coverage.**
Neither half is a finding: nothing here was reproduced, and this file's own rule forbids opening a finding that was not.
Establish coverage with the enumeration method above, which will tell you which login-free surfaces the limiter does not reach.
Then read the limiter itself and ask which value it keys a client on, whether that value is one the client can set such as `X-Forwarded-For`, whether its counters are shared across processes or held per process, and whether it returns early outside prod.
A client-settable key and a per-process counter each change what the limit actually bounds, and both have to be established against the deployed stand rather than argued from the source.

## Keeping this skill current

Treat the file as having three parts with different lifetimes.

**Permanent.** The authority rule, the active-check prohibitions, the four elements of a finding, the split between the development half and the security half, and grading by reachability rather than by catalog entry.
These change only by a captain decision, never by a standards release and never because the product moved.

**Durable.** The shapes, the classes that attach to them, and the checks in the third column.
A shape and its class do not rot when a file is renamed or a reader opens a different branch, and a check keyed on a route string, a dependency name or a settings key survives both, which is why the map is written that way rather than as a list of files.
These go stale only when the product grows a shape that has no row, or when a check's key stops being the thing worth searching for.

**Perishable.** The editions table, bound to whichever revision of each standard is current, and the two stamped product facts above, which carry the date and commit they were checked on.
Both are wrong the moment their subject moves, and neither announces it.

Revise on any of these conditions, not on intention.
Each names an act the specialist completes alone in the pass it fires: verify, then record the concrete correction and route it through the delivery path named at the end of this section.
The edit lands when that change is merged, which is not the specialist's to grant, so no condition below asks for a landed edit as its same-pass obligation and none of them is discharged by intending to get to it.

- On the first stand check of each calendar quarter, reopen every primary URL in the editions table and route the `Checked` dates that re-reading establishes; a row whose date is more than one quarter old is stale by definition and may not be cited until it has been re-verified, whether or not the re-stamp has landed.
- When a check in the third column returns nothing at the ref you are reviewing, establish whether the surface moved or went away, and route the corrected search key in the same pass.
- When a finding fits no row of the shape map, the map is missing a shape: route the new row in the same pass that files the finding.
- When either stamped fact fails its own re-check, route the correction in the same pass and grade the finding in front of you on what you observed rather than on the stamp.
- When an active check needs a technique the source in force does not cover, record which source fell short and what was used instead.

Signs that a revision is already overdue, each of them observable rather than felt:

- A primary source's page names an edition identifier that differs from the one in the table.
- A check's search key returns nothing, or returns so much that it no longer locates a surface.
- Two consecutive quiet daily reviews over a product area that did ship changes, which means the map is pointing at the wrong question rather than that the area is clean.
- A finding that had to ship without element 4 because the suite names no test for the guard, which is the answer to record rather than a gap to paper over.
- A row whose class no longer attaches to anything its checks can find.

A revision to this file edits firstmate's shared tracked material, so it is not a self-service edit.
Route it through the normal delivery path with `firstmate-coding-guidelines` loaded, and expect the captain to hold the merge.
Until that lands, cite what you actually verified rather than the row you believe is stale.
