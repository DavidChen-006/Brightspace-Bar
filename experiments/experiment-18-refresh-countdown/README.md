# experiment-18-refresh-countdown

**Question:** can the dropdown show a "Refreshes in N min" countdown — RepoBar's
"resets in 40 minutes" line — that is *correct at the moment the menu opens*,
with no ticking display timer? And does the same mechanism fix the existing
staleness bug, where "Updated just now" can sit in the menu 14 minutes after the
fetch because nothing repaints between timer ticks?

**Answer: yes to both.** 86/86 tests green, launch smoke green. Three changes,
copied-from/inspired-by RepoBar, all in the exp-5 scaffold this repo was seeded
from — the diff against `experiment-5-menubar` *is* the port list.

## The mechanism (RepoBar's, verified here)

Nobody ticks. The model carries **absolute dates**; the GUI formats them into
relative strings **lazily, at the moment the menu opens**, inside
`NSMenuDelegate.menuWillOpen` — which AppKit delivers synchronously *before*
drawing, so the re-title needs no async hop and cannot race the display. A menu
stays open for seconds and its text has minute precision, so a snapshot at open
is indistinguishable from a live countdown.

## The three changes

1. **`.status` carries dates, not baked strings** — `MenuRow.status(StatusStamp)`
   with `.updated(Date?)` / `.nextRefresh(Date)`, formatted by the new pure
   `CourseMenu/StatusText.swift` (rules pinned in `StatusTextTests`; the
   "Updated" table is exp-5's verbatim, the countdown rounds to the nearest
   minute and clamps past deadlines to "Refreshes soon").
2. **`RefreshScheduler.nextFireDate`** — production's scheduler copied
   near-verbatim, plus one derived property over `Timer.fireDate` (never a
   stored copy, so tolerance and sleep-coalescing are reflected). The adapter
   reads it live through a `NextRefreshProvider` closure on every snapshot;
   `MenuAdapter` also gained the production `timerTick()` path.
3. **`menuWillOpen` re-titles the time rows** — `MenuFreshnessDelegate` in
   `MenuAssembler.swift` walks the items and recomputes titles for rows carrying
   a `StatusStampBox`, touching nothing else.

## Findings beyond the plan

- **The model became time-invariant** — the change pays for itself twice.
  Baked strings made identical data compare unequal every minute, so the
  `Equatable` skip-rebuild the contract advertises never actually skipped across
  timer ticks. With dates in the model it does (pinned by `modelIsTimeInvariant`).
- **`NSMenu.delegate` is weak, and that bit us immediately.** The first cut
  parked the freshness delegate on the assembler; the tests found
  `menu.delegate == nil` the moment the assembler went out of scope. Fix:
  `AssembledMenu` (an `NSMenu` subclass) strongly anchors its own delegate, so
  the wiring survives any retention pattern. **Port this subtlety with the code.**
- What headless tests cannot prove — that AppKit calls `menuWillOpen` before
  drawing — is documented behaviour and the mechanism RepoBar ships on
  (`StatusBarMenuManager.swift:262`); the live run below confirms it visually.

## Run it

```sh
swift test                    # 86 tests: formatter, translation, scheduler, open-freshness
./Scripts/run.sh --smoke      # build, bundle, launch, verify alive, kill
BRIGHTSPACEBAR_STUB=1 ./.build/debug/BrightspaceBar   # live demo, no backend:
```

The stub seeds `.updated(now)` and `.nextRefresh(now + 15 min)` — open the menu
repeatedly and watch "Updated just now" age, the countdown fall, and (past the
deadline) the clamp to "Refreshes soon", all with zero repaints in between.
`BSB_INTERVAL=90` shortens the real timer for a live-path demo.

## Port map (production `BrightspaceBar/`)

| Experiment file | Production target |
|---|---|
| `CourseMenu/MenuModel.swift` (StatusStamp) | `Modules/CourseMenu/Sources/MenuModel.swift` |
| `CourseMenu/StatusText.swift` | new file, same module |
| `MenuAdapter/MenuTranslation.swift` (status rows, `nextRefresh:` param) | `Modules/MenuAdapter/Sources/MenuTranslation.swift` (drop its status formatter) |
| `MenuAdapter/MenuAdapter.swift` (`NextRefreshProvider`) | `Modules/MenuAdapter/Sources/MenuAdapter.swift` (already has `timerTick`) |
| `BrightspaceBar/RefreshScheduler.swift` (`nextFireDate` only) | `Modules/CoursePipeline/Sources/RefreshScheduler.swift` |
| `BrightspaceBar/MenuAssembler.swift` (AssembledMenu, StatusStampBox, MenuFreshnessDelegate, `now:` injection) | `Modules/BrightspaceBar/Sources/MenuAssembler.swift` |
| `BrightspaceBar/main.swift` (provider wiring; timer already exists there) | `Modules/BrightspaceBar/Sources/main.swift` |

Production extras to mind: its `MenuTranslation` genuinely uses `now`
(visibility, due dates) and its stub carries more rows; the mechanical shape of
the change is identical.
