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

Before probing any surface, establish what that surface causes our own application to do.
Reaching a third party through our own application in order to reach, measure or stress that third party is an act directed at it, so probing our surface to see what the provider does, repeating a probe to observe the provider's rate, capacity or failure behaviour, and choosing a surface because it reaches a provider are the forbidden act wearing our application as a costume, and the rule above forbids each of them with no conditions.
Our application's own ordinary single call falls outside that category by construction, since a probe of our surface that causes the outbound call our application would make anyway in normal operation is our application working rather than an act aimed at the provider.
The restraints that still bind on such a probe are to keep it to the minimum that answers the question about our surface, to prefer a surface that does not relay wherever one answers the same question, and not to repeat it in order to observe the provider's rate, capacity or failure behaviour, since repetition for that purpose is the resource-exhaustion prohibition above reaching through the relay.
The prohibition binds on that purpose rather than on a second request as such, so re-running one probe to confirm a result you doubt remains ordinary careful work.
Where such a probe would write something a person can see, the teardown rule above applies and you must be able to remove what was written.
Where you cannot remove it, the probe is not run, and the rule above on what stays unproven applies.

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
| [OWASP Top 10](https://owasp.org/Top10/2025/) (web) | 2025 | 2026-09-04 | The platform's HTTP surface. A01 Broken Access Control is the lens for tenant separation; A03 Software Supply Chain Failures is new in 2025 and widens 2021's vulnerable-components entry to the whole ecosystem; A10 Mishandling of Exceptional Conditions is new in 2025 and is the lens for the fail-open seams the environment-conditional row below says how to find. |
| [OWASP GenAI LLM Top 10](https://genai.owasp.org/resource/owasp-genai-llm-top-10-2026/) | 2026, published 2026-08-03 | 2026-09-04 | The voice agent, and the more important of the two lists for this product. Its own resource page calls it the latest community-driven guide to the most critical security risks facing applications powered by large language models, and states that it introduces updated rankings and expanded threat coverage. The 2026 entry identifiers could not be established from either reachable page and must come from the document itself before any single identifier is cited, and because the edition changes rankings the 2025 numbering may not carry over. Note the trap that produced the earlier error in this row: as of the same check date the project's own landing page at https://genai.owasp.org/llm-top-10/ still presents the 2025 edition as current and still lists the LLM01:2025 through LLM10:2025 identifiers, so that landing page lags its own project's newest release. |
| [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/) | 5.0.0, released 2025-05-30 | 2026-09-04 | Source for element 4 of a finding. Use it to derive the verification step, not as an audit checklist to walk end to end. |
| [OWASP WSTG](https://owasp.org/www-project-web-security-testing-guide/) | 4.2 stable, released 2020-12-03; 5.0 in development | 2026-09-04 | Procedure for the active check against our stand. This is the oldest source we lean on, so treat its technique list as a floor and not as coverage. |
| [OWASP Agentic AI - Threats and Mitigations](https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/) | Published 2025-02-17, first guide of the Agentic Security Initiative | 2026-09-04 | Tool-calling threat modelling. Two things could not be established from the landing page and must come from the whitepaper itself before being cited: its version, and its threat identifiers, which the page does not enumerate. |
| [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html) | Living document, carries no version or last-updated marker | 2026-09-04 | Secrets handling and leak detection. Note the standing tension it can create: it holds that environment variables are not recommended unless other methods are impossible, while a compose-deployed service is commonly handed its credentials through runtime environment. Establish for each credential how it is actually delivered and whether that delivery is a recorded product choice, and raise a recorded choice only with evidence of an actual leak path, never as a conformance complaint. |

Two deliberate exclusions, so they are not re-litigated every cycle.
Establish the deployment shape before applying the first of them: where the deployment is a single-VM `docker compose` deployment whose build produces no artifact anyone else consumes, build-provenance frameworks are out of scope and the supply-chain question is dependency currency and provider trust rather than attestation, and the Dependencies row below says how to establish what CI actually does rather than asserting it here.
Physical security, social engineering, and offensive action against third parties are outside the domain entirely.

## Product shapes and the classes that attach to them

This is the part worth reading.
Restating the ten entries of either list in the agent's own words is worthless, because the specialist already knows them and such a restatement carries no route into our code.
The value is the mapping below, and the mapping is deliberately not a list of files.

A shape and the class that attaches to it are durable, while a path, a line number, a count, and a reachability grade are not, so a map written as a snapshot of those begins rotting the day it is written.
The third column therefore says how to find the surface and what to ask of it, keyed on route strings and path prefixes, dependency and decorator symbols, settings keys, and function or helper names, all of which move far more slowly than the files that hold them.
A locator key names something expected to exist and its job is to find a surface, so it must resolve at the ref or it locates nothing and the row is worthless, and a token you established to be absent can never become one.
A token named as the object of an existence check is the other kind: it names a conventional location or filename whose presence or absence is itself the answer being sought, so it need not resolve, and each row must make plain which of the two it names so that an empty result is never read as a broken pointer.
Run each search in the parlino repository at the ref you are actually reviewing, and read a search that returns nothing as a narrowing rather than as an answer: it establishes that the key no longer locates the surface and settles nothing beyond that.
Before recording either that the surface moved or that it is no longer there, run a second search of a different kind from the one that failed, because a second search counts only where it could succeed where the first could not: where the first keyed on a symbol, key the second on the route string, the path prefix or the status code the surface should produce, and where the first keyed on a route string or a path prefix, key the second on the symbols that implement or call it.
Where that second search finds the surface, the correction is the key it turned up under.
Where it comes back empty too, record that the surface's existence is not established at your ref rather than that it is gone, because one empty grep does not establish absence over a tree.

Element 4 is composed by the specialist and never assumed, so an existing passing test is not element 4 and a suite that names nothing never excuses a finding from carrying one.
What the suite establishes is the context for composing it, so search the test suite for the guard's own symbol - the dependency, the settings key, or the function the branch sits in - and read what the match actually asserts rather than trusting a file whose name sounds right.
That search establishes which tests name the guard directly, and it cannot establish the opposite, because a route-level test that drives an unauthenticated client at the route's own path string and asserts the status code the guard should return pins that guard without naming the dependency, the settings key, or the function the branch sits in.
So when the symbol search comes back empty, search the suite again for the route string or path prefix the guard covers and for that status code, which is the second place the answer can live.
Only when both searches come back empty may the finding say the guard appears unpinned at your ref, under the search rule above, which is why it must say "appears" and name both searches that returned nothing; either way, what the suite pins is context for composing element 4 and tells you where the probe you compose belongs.

Two questions come up often enough to deserve a stated method rather than a stored answer, because a stored count is wrong on the day a route is added.

**Which surfaces are reachable without a login.**
Enumerate the application's own route table, the collection of registered routes the framework exposes on the application object once the factory has built it, because every path that application serves is registered there whatever mechanism attached it, and a mounted sub-application appears there as the mount it is.
That completeness is over attachment mechanisms and not over environments, since the table is the one the settings in force when the object was built produce, so build it under the environment you are grading and record which environment that was, because a finding resting on the enumeration is a finding about that environment.
Expect a factory that validates its configuration on startup to refuse to build under a production environment without real secrets, and satisfy that validation with placeholder values distinct from the defaults rather than with real credentials.
Where the factory still cannot be built, the source-side sweep below is the enumeration rather than a reconcile against it, and the finding says which environment the enumeration actually reflects.
Then reconcile that table against the source by walking the routers registered in the factory, the route decorators under the API package, and the routes and mounts declared directly on the application object, attributing each served path to the code that registered it and looking hardest at registrations that sit behind an environment condition, since those are what a table built under one environment silently omits and the "Environment-conditional auth" row below already owns.
The principle survives a change of framework or of attachment mechanism: enumerate from what the application actually serves and then reconcile against the source, rather than trying to enumerate every way a path can be attached, since a source-side sweep finds only the attachment shapes it was written to look for.
Classify each entry by whether the route or its router carries an auth dependency from the `require_*`, `resolve_operator` and `scoped_tenant` family or a route-specific guard, and read every unguarded one rather than trusting the classification, because a guard can also sit inline in the handler body.
Examine a mount for what it actually serves rather than assuming it is static, since the application behind it carries its own routes and its own guards or lack of them.
Then ask three further questions of each, because they separate grades that must not be collapsed: whether it is served in prod at all or sits inside an `is_prod` guard in the factory; whether a `rate_limit` call covers it, which you establish from that symbol's call sites; and whether it carries a credential outside the `Authorization` header, such as a token in a query parameter or an `X-API-Key`, which makes it credential-bearing rather than anonymous.
Check the factory for app-level middleware too, since a dependency added there would cover routes that look unguarded one at a time.

**Whether a guard actually gates.**
Do not read a dependency's name as its behaviour.
Follow it to its body and look for an environment branch, and establish for yourself what each side of that branch permits.
Where such a branch exists, the same route grades differently in different environments, and a finding must say which environment it was checked in.
That is the "Environment-conditional auth" row below, and it is the most common reason a grade written from a function name is wrong.

| Shape | Class that attaches | How to find the surface and what to check |
|---|---|---|
| Multi-tenancy and data separation | Broken access control; horizontal privilege escalation across tenants | Find the tenant-scoping helpers by searching for `may_touch_tenant` and `scoped_tenant`, then find every route that resolves a tenant id from the request rather than from the caller's own scope. Check whether authorization runs before the lookup: a handler that fetches first and authorizes second lets an operator tell an existing foreign id from a missing one by the status code alone |
| Environment-conditional auth | Mishandling of exceptional conditions; fail-open under an unexpected configuration | Search for `is_prod` and read every branch it guards, asking for each what the non-prod side permits and which routes inherit it through a dependency. Find the pinning test per branch by searching the suite for that branch's own symbol, not for a file whose name suggests security: a suite that pins the auth guards may not touch the limiter, and coverage is per branch rather than per file |
| Voice, recordings, transcripts | Sensitive information disclosure; broken object-level authorization on media | Find the media routes by their `/audio` path suffix and the `recordings_root` settings key. Check that one call's audio is authorized against the caller's own tenant rather than merely existing, then find every place recorded audio and transcript text comes to rest, searching for the worker-side `audio_tap` telemetry module, the `append_lead` function and the `_LEADS_PATH` constant holding its leads file path, as well as the platform's own media routes. For each copy, check whether the same authorization that guards the media route also runs before that copy is read, and read a copy that no such check reaches as a disclosure path the media route's own guard does not close |
| Agent tool calling | Excessive agency; improper output handling; tool abuse | List the tools actually registered on the agent by searching for the `function_tool` registrations, and compare that list against the tool names the agent spec permits. For each, ask what it can do that the caller could not, whether its result returns to the model as text, and whether any veto on it is binding or advisory |
| Knowledge base and retrieval | Vector and embedding weaknesses; indirect prompt injection through retrieved text; cross-agent vault leakage | Follow one document from upload through ingestion to the index and back out through retrieval, searching for `materialize_agent_kb` and the knowledge-base search tool the agent registers. Check whether the index is partitioned per agent and per tenant, and whether retrieved text enters the prompt with any marking that separates it from instructions |
| Prompt assembly and guardrails | Prompt injection; system prompt leakage | Find where the system prompt is assembled and every value interpolated into it, searching for the prompt-spec builder and for the `guardrails` and `out_of_scope` spec fields, then classify each input as enumerated, operator-authored, or free text from the caller or from retrieval. Establish for each what constrains its values before it reaches the prompt, start from any input that no such constraint reaches, and read the guardrail module's own stated enforcement level before treating it as a mitigation |
| Public landing and pilot form | Unauthenticated write surface; anonymous free text that can be stored and relayed verbatim into an operator-facing channel; unvalidated personal data taken on an unauthenticated write path; abuse of a billed resource | Find the public form route by its `/api/public/` path prefix, then follow each submitted field to storage and to the notification sender, which you locate by searching for `notify_pilot_request` and the private `_send` helper beside it in the notification module. Check what bounds each field and where the text is rendered next, then establish whether that sender sets any parse or formatting mode on the outgoing message before naming a markup-injection class, because a channel posted as plain text carries none |
| Operator and client screens | Token handling in the browser, including a credential placed somewhere other than a header where proxy logs, browser history and referrer headers can see it; authorization enforced only in the UI | Find where the frontend stores the token by searching for its storage key and for `getToken`, then search the frontend for `?token=` to find every place that credential is interpolated into a URL rather than into a header. Check every role comparison in the client's route guards and confirm the same check exists server-side, since a guard that lives only in the UI is not one |
| Telephony and channels | Provisioning against an external provider; admission and plan enforcement on a worker-authenticated internal path, where an identity conveyed by the caller can stand in for one the platform authenticated | Find the internal SIP admission route by its `/api/internal/` path prefix and its `require_worker` dependency, then read what it mints and which gate it runs. Check that its plan gate matches the web path's, and treat the provider-provisioning modules as the separate question of credentials held for an external provider |
| Calendar integration and booking | Stored third-party OAuth refresh and access tokens at rest; a callback reachable without an `Authorization` header, whose guard is whatever validates its state; open redirect through a return-to value; cross-tenant reach into another tenant's calendar | Find the OAuth surface by searching for `create_oauth_state`, `decode_oauth_state`, `safe_oauth_return_to` and `PLATFORM_ENCRYPTION_KEY`. Check which routes sit on the callback router rather than the operator router, since a callback entered by a redirected browser is guarded only by whatever validates its state; check that credentials reach the database through one module only and encrypted; and check the return-to value against its allowlist |
| Public cached proxies | Unauthenticated outbound amplification and unbounded consumption, where an anonymous request can make the server issue an outbound call on a cache miss; dependence on a third party the specialist may not probe | Find the public routes that perform outbound I/O by searching for the `worker_health_url` settings key and for the module-level `_probe` and `_fetch` helpers, and find their cache behaviour by searching for the `_CBR_URL` constant that holds the third-party URL and for the `_CACHE_TTL_S` and `_TTL_S` cache time-to-live constants. Check whether any part of the destination comes from the request, since only that would make it forgery rather than amplification, and check whether a single-flight guard exists at all, since that and not the placement of the cache timestamp is what decides whether concurrent misses collapse into one outbound call or fan out into many |
| Usage limits | Unbounded consumption | Find the admission points by searching for `check_quota`, and the plan table behind it. Check whether the check runs once at admission or repeatedly, and what is recorded when an admitted call overruns |
| Secrets | Credential exposure through logs, images, and CI | Regenerate the set of credentials rather than recalling it, by enumerating the credential declarations in the example environment file at the repository root together with the settings fields that read them, which is the manifest for what the application reads, and the secret references in the CI workflows together with anything the deploy scripts write to disk, which is where a credential the deployment holds but the application never reads lives; search for each name either query yields, and read `PLATFORM_AUTH_SECRET` and `TELEGRAM_BOT_TOKEN` as illustrations of the shape those names take rather than as the set. Find where a credential carried in a request URL would otherwise reach the logs by searching for the `create_app` factory and for the `httpx` and `httpcore` logger names it quiets. Check where each is read and where it could reach build output, CI logs or a request URL, and name any secret you find by its location and never by its value |
| Dependencies | Software supply chain failures | Find the lockfiles and anything downloaded at build or run time, such as a model pulled by the knowledge-base embedder. Check whether anything alerts on a vulnerable dependency, and read all three places that answer can live rather than assuming it either way: the workflow directory for a scanning job, the forge directory itself for a dependency-update configuration file at the conventional name `dependabot.yml`, which sits beside the workflow directory rather than inside it and is named here as the object of an existence check rather than as a locator, so its absence is one of the answers and not a broken key, and the repository's own vulnerability-alerting settings, which are not files in the tree at all. An empty search of the first two says nothing about the third, which is no file in the tree and which the specialist may have no read access to at all, so the search rule above governs what may be recorded |

Two facts about this product do not follow from reading a route, and a specialist who does not know them will mis-grade every finding that touches them.
Both were checked in the parlino repository on 2026-09-04 at `develop`, commit `27644cd9fee528bc0a641ab7339cd975d9774030`, and both are written so you can re-check them rather than having to trust them.
A third note follows them, separated because it is not a stamped fact and asserts nothing.

**Guardrails detect, and they do not block.**
The guardrail checker states its own enforcement level in its module docstring: prompt-side prevention plus fire-and-forget detection after the reply, never blocking.
Re-check by reading that docstring and confirming that no caller awaits a verdict before the reply is sent.
A defect that is "caught by a guardrail" is still reachable, so never record one as mitigated.

**Quota grants deliberate grace to the call in hand.**
Admission is checked once and never re-checked mid-call, and an overrun is recorded as real usage so that the next call is refused instead.
Re-check by reading the quota module's admission function and the test that pins the grace behaviour, which you find by searching the suite for that function's name.
This is a product guarantee rather than a defect, so unbounded-consumption work belongs at the admission points and never in a proposal to cut a live call off.

**The rate limiter is a place to look, and its key is a separate question from its coverage.**
Neither half is a finding yet, because nothing here has been reproduced or demonstrated, which is what "What makes a finding a finding" above requires.
Establish coverage with the enumeration method above, which will tell you which login-free surfaces the limiter reaches and which it does not.
Then establish the following about the limiter itself, treating none of them as settled by one source alone.
What value it keys a client on, which you read in the limiter.
Whether a client can control that value, which depends on what the limiter extracts from it where it is a multi-valued header such as `X-Forwarded-For`, on how anything standing in front of the application treats that header, and on whether the application can be reached without traversing that thing at all, so the source and the deployment configuration are both load-bearing and neither answers it by itself.
Whether the counter is shared or process-local, where the limiter's body gives the mechanism and the deployment configuration gives whether more than one process serves the surface, so again neither alone.
The body also shows whether the limiter returns early outside prod, which the environment-conditional method above governs.
All of these are source and configuration reads that stay inside the boundary above and need no traffic, and driving requests past the limit to establish any of them is the resource-exhaustion testing the active-check rules above forbid.
Where a value's controllability cannot be established from those reads, record it as not established rather than grading it either way.

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

- When a row of the editions table is about to be cited and its `Checked` date is more than a quarter old, reopen that row's primary source first, looking for a newer release resource published under that project rather than reading its landing page alone, and route the `Checked` date that re-reading establishes in the same pass, whichever activity the pass is; a row whose date is more than one quarter old is stale by definition and may not be cited until it has been re-verified, whether or not the re-stamp has landed.
- When a check in the third column whose key is a locator returns nothing at the ref you are reviewing, run the second search the map's own search rule above requires before concluding anything, and route a correction in the same pass for whichever that establishes: the corrected search key where the surface turns up under a changed key, or, where the second search is also empty, the record that what the check names is not established at that ref, routed as a proposal to drop that check or its row rather than as a removal made on one empty result; a token named as the object of an existence check is outside this condition, because an empty result there is that check's answer and triggers nothing.
- When a finding fits no row of the shape map, the map is missing a shape: route the new row in the same pass that files the finding.
- When either stamped fact fails its own re-check, route the correction in the same pass and grade the finding in front of you on what you observed rather than on the stamp.
- When an active check needs a technique the source in force does not cover, record which source fell short and what was used instead.

Signs that a revision is already overdue, each of them observable rather than felt:

- A primary source's page names an edition identifier that differs from the one in the table.
- A project's landing page names an older edition than one of that project's own release resources.
- A check's search key returns nothing, or returns so much that it no longer locates a surface.
- Two consecutive quiet daily reviews over a product area that did ship changes, after which re-read that area's checks to establish whether they still reach what shipped or the area was genuinely clean.
- A row whose class no longer attaches to anything its checks can find.

A revision to this file edits firstmate's shared tracked material, so it is not a self-service edit.
Route it through the normal delivery path with `firstmate-coding-guidelines` loaded, and expect the captain to hold the merge.
Until that lands, cite what you actually verified rather than the row you believe is stale.
