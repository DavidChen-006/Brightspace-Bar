# Experiment 4 — The course pipeline

Everything between "we have a JWT" and "a menu could render this," with **zero GUI**.

690 lines of Swift behind 54 tests. Both green.

## Run it

```bash
swift test                # 54 tests, hermetic — no network, no session.json needed
BS_LIVE=1 swift test      # same 54, but the contract suite also hits the real tenant
```

The hermetic run must pass on a plane. If it ever needs the network, something leaked.

## Layout

| File | Lines | Role |
|---|---|---|
| `Contracts.swift` | 126 | the frozen seams: `Course`, `CourseSourceError`, `CourseSource`, `Clock`, `CacheOutcome`, `PollTrigger` |
| `EnrollmentParser.swift` | 134 | pure core — `Data` → `[Course]` or a typed error |
| `CourseCache.swift` | 108 | pure `fold` decision + actor shell over an atomic JSON file |
| `PollPolicy.swift` | 36 | pure core — the entire "should we fetch?" decision |
| `Poller.swift` | 85 | shell — source + cache + policy, with in-flight coalescing |
| `BrightspaceCourseSource.swift` | 201 | the real adapter: cookie → JWT → GET → parser |

`FakeCourseSource` lives in the test target. Both sources are held to one contract suite.

## Decisions and why

**Parsing skips a bad item rather than failing the payload — with an all-items-unusable
backstop.** Argued by blast radius: if D2L emits one malformed item of 27, failing the
whole parse yields `.malformedBody` → `.preservedStale` → an empty menu on cold start, so
one broken course costs all 27. Skipping shows 26 and the user works. The backstop is what
keeps "skip" from degenerating into a silent empty list.

**Stub detection is decode-first, then check for the literal `sessionExpired=1` marker.**
Generic HTML — a 502 page — must be `.malformedBody`, not `.sessionExpired`, or every
Brightspace outage drags the user through a pointless MFA re-login.

**`homeUrl` is preserved verbatim, nulls included.** Measured: non-null in only 2 of 27
items; every real class sends `null`. The click action must derive `{baseUrl}/d2l/home/{id}`
at the UI layer. An earlier SPEC draft wrongly claimed it was always populated.

**`.unchanged` advances `lastFetch` in memory but does not write the file.** Without the
advance, `isStale` stays true forever and a timer poller hammers the server every tick.
Not persisting it costs at most one extra fetch after relaunch.

**`apply` compares in-memory state and never re-reads disk** — enforced by a sentinel test
rather than by mtime, because mtime can false-pass when granularity exceeds the write gap.

**Staleness is inclusive** (`age >= interval`): a repeating timer firing exactly on its
period is the common case, and exclusive would make a punctual timer decline.

**A future-dated `lastFetch` counts as stale.** Clock skew and laptop sleep both produce
negative age, and a naive `age >= interval` wedges permanently — unrecoverable without
deleting the cache file.

**Failure does not consume the interval**, so an offline app retries the moment the user
reopens the menu.

**`Poller` holds no `lastFetch` of its own** — it reads the cache's. One source of truth.

## Findings

**Actor isolation alone does not prevent overlapping fetches.** `await` inside an actor
method is a suspension point that admits reentrant callers, so N concurrent ticks can all
clear the staleness check and all hit the network. Fixed with an explicit in-flight `Task`
plus a `completedFetches` epoch counter: `await cache.lastFetch` is *itself* a suspension
point, so a whole fetch can start and finish during that read, leaving a tick acting on a
stale snapshot with `inFlight == nil` again. Without the epoch guard the concurrency test
passes only by grace of effectively-FIFO actor scheduling, which Swift does not guarantee.

**The fake did not drift.** Fixture yields 27 courses; the live tenant yields 27. That is
what the parameterised contract suite exists to prove — assertions written once, run
against both implementations.

**Auth failure is asymmetric, and narrower than assumed.** The cookie-authenticated token
mint answers a dead session with **HTTP 200** and a 294-byte HTML stub. The
bearer-authenticated API behaves correctly, returning a real `401` with RFC 7807
`problem+json`. So the stub guard belongs only on the mint path.

**27 "active" courses span multiple terms** — the payload includes
`Spring 2025 SCLA 101 Transformative Texts - Merge` under `isActive=true`. Deciding what a
menu actually shows is a data-shaping problem, and a pure one.

## Not done here

No GUI. No `NSStatusItem`, no app bundle. The next unknown is whether `swift build` output
can be assembled into a launchable `.app` — RepoBar needs ~255 lines of shell and an
`Info.plist` with `LSUIElement` to manage it, and that risk is invisible from every layer
in this package.
