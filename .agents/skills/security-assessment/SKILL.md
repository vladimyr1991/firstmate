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
Build-provenance frameworks are out of scope for a single-VM `docker compose` deployment whose only workflow is `.github/workflows/deploy.yml`; for our shape the supply-chain question is dependency currency and provider trust, not attestation.
Physical security, social engineering, and offensive action against third parties are outside the domain entirely.

## Product shapes and the classes that attach to them

This is the part worth reading.
Restating the ten entries of either list in the agent's own words is worthless, because the specialist already knows them and such a restatement carries no route into our code.
The value is the mapping below.
Every path below is relative to the parlino repository root and was read there on 2026-09-04 at `develop`, commit `27644cd9fee528bc0a641ab7339cd975d9774030`, whose tip is dated 2026-09-02 and titled "Merge demo calendar seeder".
The ref is part of the address rather than decoration, because parlino's `main` is a stale release line (`13e9eb0`, tag `v0.12.0`, 2026-07-29) on which `voice_ai_workers/refusal.py`, `voice_platform/test_quota_grace.py`, and `voice_shared/niches.py` do not resolve at all.
A reader who opens the default branch instead will hit dead pointers that say nothing about whether the map is wrong, so resolve every path below against `develop`.

| Shape | Class that attaches | Where to look |
|---|---|---|
| Multi-tenancy and data separation | Broken access control; horizontal privilege escalation across tenants | `voice_platform/api/deps.py` (`OperatorScope.may_touch_tenant`, `scoped_tenant`, `require_operator`, `require_worker`, `require_operator_or_worker`), `voice_platform/api/portal.py` (`_resolve_tenant_id`, `_get_tenant_call`), `voice_platform/api/calls.py` |
| Environment-conditional auth | Mishandling of exceptional conditions; fail-open under an unexpected configuration | The `settings.is_prod` branches in `voice_platform/api/deps.py` and `voice_platform/ratelimit.py`, pinned by `voice_platform/test_security.py` |
| Voice, recordings, transcripts | Sensitive information disclosure; broken object-level authorization on media | `voice_platform/api/calls.py` (`audio_router`, `_require_operator_for_audio`), `voice_platform/api/portal.py` (`portal_audio`), `recordings_root` in `voice_platform/settings.py`, `voice_ai_workers/telemetry/audio_tap.py`, `voice_ai_workers/memory/store.py` |
| Agent tool calling | Excessive agency; improper output handling; tool abuse | `voice_ai_workers/agent.py` (`end_call` and its `evaluate_end_call` veto, `search_knowledge_base`, `_make_handoff_tool`), the `tools` field of `AgentSpecPayload` in `voice_shared/spec.py` |
| Knowledge base and retrieval | Vector and embedding weaknesses; indirect prompt injection through retrieved text; cross-agent vault leakage | `voice_ai_workers/kb/` (`ingester.py`, `retriever.py`, `index.py`), `voice_platform/api/kb.py`, `voice_platform/config_service/kb.py` |
| Prompt assembly and guardrails | Prompt injection; system prompt leakage | `voice_ai_workers/prompt_spec.py`, `voice_ai_workers/prompts.py`, `voice_ai_workers/refusal.py`, `voice_ai_workers/guardrails/checker.py`, the `guardrails` and `out_of_scope` fields in `voice_shared/spec.py` |
| Public landing and pilot form | Unauthenticated write surface; injection into a downstream channel; abuse of a billed resource | `voice_platform/api/pilot_requests.py`, `voice_platform/api/tokens.py`, `voice_platform/ratelimit.py`, `voice_platform/notify.py` |
| Operator and client screens | Token handling in the browser; authorization enforced only in the UI | `frontend/src/auth.jsx`, `frontend/src/api.js`, `frontend/src/components/ui.jsx` |
| Telephony and channels | Untrusted inbound identity; provisioning against an external provider | `voice_platform/api/sip.py`, `voice_platform/api/channels.py`, `voice_platform/sip_providers.py`, `voice_platform/sip_provision.py` |
| Calendar integration and booking | Stored third-party OAuth refresh and access tokens at rest; an unauthenticated callback whose only guard is a signed and fresh state; open redirect through the return-to value; cross-tenant reach into another tenant's calendar | `voice_platform/api/integrations.py` (`connect`, `callback`, `disconnect`, `test_google_connection`, `oauth_state_claims`, `_revoke_best_effort`), `create_oauth_state`, `decode_oauth_state` and `safe_oauth_return_to` in `voice_platform/auth.py`, `voice_platform/crypto.py` (`PLATFORM_ENCRYPTION_KEY`, `SecretsUnavailable`, `SecretDecryptionError`), `voice_platform/integrations/store.py` (`set_refresh_token`, `set_access_token`), `voice_platform/integrations/calendar_google.py`, `voice_platform/integrations/calendar_provider.py`, `voice_platform/api/booking.py`, `voice_platform/scheduling/` (`booking_config.py`, `booking_errors.py`, `slot_id.py`, `store.py`), the `IntegrationConnection` model in `voice_platform/db/models.py`, the `GOOGLE_OAUTH_*` block in `.env.example`, pinned by `voice_platform/test_integrations_oauth.py` with `voice_platform/test_calendar_provider.py` and `voice_platform/test_scheduling.py` |
| Public cached proxies | Server-side request forgery shape and unbounded consumption, in that an anonymous caller with no credential makes the server issue an outbound request on its behalf on a cache miss; dependence on a third party the specialist may not probe | `voice_platform/api/worker_status.py` (`_probe`, `_CACHE_TTL_S` of about two seconds, `worker_health_url` in `voice_platform/settings.py`), `voice_platform/api/fx.py` (`_fetch`, `_CBR_URL` at the third-party `cbr-xml-daily.ru`, `_TTL_S` of about twelve hours, `_FALLBACK`) |
| Usage limits | Unbounded consumption | `voice_platform/quota.py`, `voice_platform/plans.py` |
| Secrets | Credential exposure through logs, images, and CI | `.env.example`, `deploy/push.sh`, `.github/workflows/deploy.yml`, the httpx log-level suppression in `voice_platform/main.py`'s `create_app` |
| Dependencies | Software supply chain failures | `uv.lock`, `frontend/package-lock.json`, the model download in `voice_ai_workers/kb/embedder.py`, and the absence of any dependency-alerting workflow beside `deploy.yml` |

Five of the rows above need a sentence the table cannot hold.

**The prompt-injection seam is narrower than it looks, and that is where to start.**
Visitor-controlled `lang` and `niche` reach the demo agent's prompt as LiveKit dispatch metadata through `TokenRequest` in `voice_platform/api/tokens.py`, and both are pinned to an enumerated regex there before `voice_shared/niches.py` mixes the visitor context into the prompt.
So the interesting question is not whether free text reaches the prompt at that door, but which other paths reach it without passing a comparable constraint - the caller's own speech, retrieved knowledge-base chunks, and operator-authored spec fields.

**Guardrails are a detection layer, not a control, and a finding must not treat them as a mitigation.**
`voice_ai_workers/guardrails/checker.py` states its own enforcement level: prompt-side prevention plus fire-and-forget detection after the reply, never blocking.
A defect that is "caught by a guardrail" is still reachable.

**Quota grants deliberate grace to the call in hand.**
`voice_platform/quota.py` admits once and never re-checks mid-call, and the overrun is recorded as real usage so the next call is refused instead.
That is a documented product guarantee pinned by `voice_platform/test_quota_grace.py`, so unbounded-consumption work belongs at the admission points rather than in a proposal to cut live calls off.

**The calendar row is where our code holds someone else's credential, and nothing in it has been reproduced.**
`voice_platform/api/integrations.py` splits its routes across two routers on purpose: everything on `router` is an ordinary operator endpoint, while `/callback` sits on `callback_router` because it is entered by a browser Google redirected, which carries no `Authorization` header, so its only authentication is the signature and freshness of the `state` minted at connect time.
Credentials reach the database through `voice_platform/integrations/store.py` and nowhere else, encrypted under `PLATFORM_ENCRYPTION_KEY` by `voice_platform/crypto.py`, and `calendar_google.py` is the only module in that package allowed to know Google.
Read those as the design's own claims and check them, rather than assuming either the claim or its breach.
`voice_platform/test_integrations_oauth.py` is the verification entry point that element 4 of a finding here draws on, and it pins the row's classes by name: `test_the_access_token_round_trips_encrypted_and_clears` and `test_set_access_token_raises_before_it_assigns_anything` for credentials at rest, `test_a_state_that_is_not_ours_and_fresh_is_rejected` and `test_a_login_jwt_and_an_oauth_state_are_not_interchangeable` for the callback's only guard, `test_a_return_to_outside_the_allowlist_never_reaches_the_state` and `test_an_allowlisted_return_to_is_where_the_callback_lands` for the return-to open redirect, and `test_delete_connection_says_nothing_about_another_tenants_row` for cross-tenant reach.
`voice_platform/test_calendar_provider.py` and `voice_platform/test_scheduling.py` carry the provider boundary and the scheduling side.
Excessive agency at the booking handoff is deliberately absent from that row, because at the pinned commit the agent cannot book: the only handoff tool in `voice_ai_workers/agent.py` is `_make_handoff_tool`, whose body moves the stage to wrapup and returns `WrapUpAgent` and nothing else, no module under `voice_ai_workers` reaches `voice_platform.scheduling`, and `voice_ai_workers/test_booking_error_tool_contract.py` opens by saying that no booking tool exists yet.
That class attaches on the day a booking tool is registered in `voice_ai_workers/agent.py`, or on the day a module under `voice_ai_workers` first imports `voice_platform.scheduling`, and not before.

**Six routes are reachable without a login at the pinned commit, and the rate limiter covers two of them.**
Reaching a route without a login is not one grade, so keep the kinds below apart rather than collapsing them into a single anonymity axis: element 3 of the finding contract distinguishes them, and grading them alike is what makes this paragraph go wrong.
The set is closed at the ref named at the head of the map, established by enumerating every router registered in `voice_platform/main.py`, which adds `CORSMiddleware` and no app-level auth dependency of its own.

`rate_limit` has exactly two call sites, and both are reachable without a login: the login route at `voice_platform/api/auth_routes.py` line 39, and the visitor token mint at `voice_platform/api/tokens.py` line 105.

Three more are mounted in prod, are genuinely anonymous, and are bounded by nothing the limiter knows about:

- `POST /api/public/pilot-request` in `voice_platform/api/pilot_requests.py`, which bounds field length only.
- `GET /api/worker/ready` in `voice_platform/api/worker_status.py`, whose own docstring calls it public and unauthenticated; each miss triggers a server-side probe of the worker health endpoint behind a cache of about two seconds.
- `GET /api/fx` in `voice_platform/api/fx.py`, documented as public and without authorization; each miss triggers a server-side fetch from the third-party `cbr-xml-daily.ru` behind a cache of about twelve hours with a fallback rate.

The sixth is state-bearing rather than anonymous, and must not be graded with the three above.
`GET /api/integrations/google-calendar/callback` in `voice_platform/api/integrations.py`, mounted from `callback_router`, carries no `Authorization` header, but its guard is the signature and freshness of a `state` that only `create_oauth_state` mints, inside `POST /connect`, which sits behind `scoped_tenant` and `resolve_operator`.
A defect there is reachable by whoever can obtain such a state, not by an anonymous caller, and grading it anonymous overstates both its reach and, under the escalation rule above, its urgency.

Three further groups sit beside the whole set and must not be folded into it, because each is a different question.
The operator and portal audio routes also arrive without the header, since a native `<audio>` element cannot send one, but each still demands a valid JWT in a `token` query parameter - the operator's through `_require_operator_for_audio` in `voice_platform/api/calls.py`, the portal user's through `decode_token` and `_resolve_tenant_id` in `voice_platform/api/portal.py`.
The worker data plane authenticates by `X-API-Key` rather than by an `Authorization` header, so `voice_platform/api/sip.py`, `voice_platform/api/ingest.py`, and `agents.snapshot_router` are credential-bearing and belong with the worker-identity question rather than with the anonymous surface.
`/dev/join` and `/dev/sip-token` in `voice_platform/api/devpage.py` sit inside the `if not settings.is_prod` guard in `voice_platform/main.py` and are not mounted in prod at all, and `GET /health`, defined inline in `create_app`, is public but returns a static status object with no I/O and no state.

None of the six is a finding: they are places to look, and the actual downstream effect of each has to be established before anything is written up.
The limiter's key is the second thing to look at, separately from its coverage.
`_client_ip` in `voice_platform/ratelimit.py` takes the first value of the request's own `X-Forwarded-For` header, the counters are per process rather than shared, and the whole limiter returns early when the environment is not prod - three properties whose consequences have to be established against the deployed stand rather than argued from the source.

## Keeping this skill current

Treat the file as having two halves with different lifetimes.

**Permanent.** The authority rule, the active-check prohibitions, the four elements of a finding, and the split between the development half and the security half.
These change only by a captain decision, never by a standards release.

**Perishable.** The editions table is bound to whichever revision of each standard is current, and the shape map is bound to the product's code as it stood at the ref and commit stated above, not merely on that date.
Both are wrong the moment their subject moves, and neither announces it.

Revise on any of these conditions, not on intention:

- On the first stand check of each calendar quarter, reopen every primary URL in the editions table and rewrite its `Checked` date; a row whose date is more than one quarter old is stale by definition and may not be cited until it is re-verified.
- When the daily review of landed work touches any path named in the shape map, correct that row in the same pass and re-stamp the ref and commit at the head of the map, before writing the day's line.
- When a finding fits no row of the shape map, the map is missing a shape: add the row in the same pass that files the finding.
- When an active check needs a technique the source in force does not cover, record which source fell short and what was used instead.

Signs that a revision is already overdue, each of them observable rather than felt:

- A primary source's page names an edition identifier that differs from the one in the table.
- A path in the shape map no longer resolves at the ref and commit named at the head of the map, or `git log --follow` shows it moved.
- A mapped path resolves differently at the tip of that ref than at the commit named there, which dates the map by its subject rather than by its calendar date.
- Two consecutive quiet daily reviews over a product area that did ship changes, which means the map is pointing at the wrong place rather than that the area is clean.
- A finding that had to ship without element 4, which means its shape row has no verification entry point yet.

A revision to this file edits firstmate's shared tracked material, so it is not a self-service edit.
Route it through the normal delivery path with `firstmate-coding-guidelines` loaded, and expect the captain to hold the merge.
Until that lands, cite the source you actually verified rather than the row you believe is stale.
