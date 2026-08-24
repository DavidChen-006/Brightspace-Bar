# experiment-13-time-sensitive-notification

**Question:** BrightspaceBar's login sometimes hits Microsoft MFA number
matching — a 2-digit code appears headlessly and the human must type it on
their phone. Can a macOS notification carry that code (a) on demand, (b)
**through Do Not Disturb** via `UNNotificationInterruptionLevel.timeSensitive`,
and (c) stay on screen for **exactly 6 seconds** and then vanish?

**Short answer: yes to firing, yes to exact 6-second control, NO to
time-sensitive.** An ad-hoc-signed local build cannot claim the time-sensitive
entitlement, and the OS silently downgrades `.timeSensitive` to `.active`. So
this app, as built, will NOT break through Focus.

## Run it

```sh
./Scripts/run.sh              # menu-bar app; click the bell icon
./Scripts/run.sh --smoke      # build, launch, verify alive, kill
./Scripts/run.sh --autofire   # fire one time-sensitive notification unattended
./Scripts/run.sh --probe      # round-trip every interruption level, log results
./Scripts/run.sh --entitled   # claim the entitlement — watch launch FAIL
```

Everything is logged with timestamps to stdout **and** mirrored to
`artifacts/run.log`, because `open` detaches stdout. Watch it live with
`tail -f artifacts/run.log`.

## Read this before you click anything

The app is currently **denied** notification permission. Fix it first:

1. **System Settings → Notifications → Exp13**
2. Turn **Allow Notifications** ON.
3. Set the alert style to **Alerts**, not Banners. This is the setting that
   decides whether "exactly 6 seconds" is even reachable — see S4 below.

Why it ended up denied: the very first launch raised the authorization prompt,
and the prompt **blocks `requestAuthorization` indefinitely** until a human
answers it. I relaunched the app while the prompt was still on screen, and
macOS recorded that as a denial. Once denied, `requestAuthorization` no longer
prompts — it returns `UNErrorDomain Code=1 "Notifications are not allowed for
this application"` immediately, forever. The only way back is the System
Settings toggle. **Gotcha worth remembering for BrightspaceBar itself: never
relaunch while the permission prompt is up.**

## Findings, by seam

### S1 — Does a notification fire at all from a locally-built unsigned .app? YES.

| Check | Result |
|---|---|
| `.app` bundle with `CFBundleIdentifier` required | CONFIRMED — the code guards on it; without a bundle id `UNUserNotificationCenter.current()` traps, and it is a hard trap, not a catchable error |
| `center.add(request)` accepted | MEASURED — returns without error in ~12ms |
| Notification reaches Notification Center | MEASURED — appears in `deliveredNotifications()` immediately |
| Menu-bar accessory app (`.accessory` + `NSStatusBar`) | MEASURED — launches, installs the bell icon, stays alive |

One subtlety that will bite anyone trusting the API alone: **`add()` succeeded
and the notification appeared in `deliveredNotifications()` even while
`authorizationStatus == denied`.** The data layer accepts and stores it; the
presentation layer drops it. `deliveredNotifications()` is therefore NOT proof
that a human saw anything. Only `authorizationStatus == 2` plus David's eyes
settle that.

### S2 — Does `.timeSensitive` work unsigned? NO. The OS downgrades it.

This is the load-bearing negative result, and it is measured three
independent ways:

**1. The settings say the app may not send time-sensitive.**

```
timeSensitiveSetting = 0    (0=notSupported 1=disabled 2=enabled)
```

`notSupported` — not "disabled by the user", but "this app is not eligible".

**2. The delivered copy comes back downgraded.** `--probe` fires one
notification at each level and reads each delivered copy back:

```
PROBE requested=passive        delivered=passive
PROBE requested=active         delivered=active
PROBE requested=timeSensitive  delivered=active      ← downgraded
```

The first two lines are the control that makes the third meaningful: the
readback API faithfully preserves `passive` and `active`, so `timeSensitive`
arriving as `active` is a real OS decision about that level specifically, not
the API flattening everything to a default.

**3. Claiming the entitlement makes the app unlaunchable.**
`com.apple.developer.usernotifications.time-sensitive` is a **restricted**
entitlement. Running `./Scripts/run.sh --entitled`:

- `codesign --force --sign - --entitlements …` **succeeds**, and
  `codesign -d --entitlements -` confirms the claim is embedded.
- Then `open` **fails to launch it**:
  ```
  Error Domain=RBSRequestErrorDomain Code=5 "Launch failed."
  NSUnderlyingError=… NSPOSIXErrorDomain Code=153 "Launchd job spawn failed"
  ```

codesign will let you *write* the claim; launchd refuses to *run* a binary
claiming a restricted entitlement that no provisioning profile authorises. Ad-hoc
signing cannot fake one. **A paid Apple Developer account and a provisioning
profile with the time-sensitive capability are the price of admission.**

### S3 — Does it break through Do Not Disturb? Almost certainly NOT, as built.

I cannot see the screen, so this needs David's eyes — but the mechanism is
settled by S2. Since `.timeSensitive` is downgraded to `.active` before
delivery, there is nothing left in the notification that Focus is supposed to
respect. An `.active` notification is exactly what Focus suppresses.

**How to test it yourself (5 minutes):**

1. Grant permission per the section above, and confirm the log line at fire
   time reads `authStatus=2`.
2. Turn Focus / Do Not Disturb **off**. Click *Fire time-sensitive* and *Fire
   normal*. Both should appear — this proves the baseline works before you
   change the variable.
3. Turn Focus / Do Not Disturb **on**. Click *Fire time-sensitive*, then *Fire
   normal*.
   - **Expected from S2:** neither appears. Both are `.active` by the time the
     OS sees them.
   - If the time-sensitive one *does* appear, that contradicts the downgrade
     measurement and is worth knowing — tell me.
4. There is a manual escape hatch: **System Settings → Focus → your Focus →
   Apps → allow Exp13**. That is a *per-app allowlist the user configures*, not
   something the app can claim, and it works regardless of interruption level.
   For BrightspaceBar this is arguably the honest path: ask David once to
   allowlist the app in his Focus, rather than buying a developer account for
   an entitlement.

### S4 — Can the duration be controlled? YES for the withdrawal, with one caveat you don't own.

**The 6-second timer is exact — measured.**

| Timing mechanism | Fired at | Verdict |
|---|---|---|
| `Task.sleep(for: .seconds(6))` | **+6.328s** | 328ms of drift — macOS coalesces timers for an idle, App-Napped `.accessory` process |
| `DispatchSourceTimer`, 1ms leeway, inside a `beginActivity` assertion | **+6.003s** | 3ms — this is what the code uses |

`removeDeliveredNotifications(withIdentifiers:)` at +6.003s **does** remove it
at the data layer: `post-withdraw: still in Notification Center = false;
remaining = 0`. Verified in the log every run.

**The caveat: whether 6 seconds is reachable is a System Settings choice, not
an app choice.**

- **Banner style** (macOS default, `alertStyle = 1` — what this app currently
  has): the OS auto-hides the banner after roughly 5 seconds on its own. A
  withdrawal at 6.0s arrives *after* the OS already pulled it, so the visible
  duration is ~5s and **6 seconds is unreachable**. You can make a notification
  shorter than the OS default this way, never longer.
- **Alert style** (`alertStyle = 2`): the notification persists until dismissed.
  Here the 6.0s withdrawal is the thing that ends it, and **exactly 6 seconds
  is achievable.**

So the answer to "can I make it stay for exactly 6 seconds and then disappear"
is: **yes, but only if the user has set Exp13 to Alerts rather than Banners in
System Settings.** The app cannot set that for itself. Flip it to Alerts and
click *Fire time-sensitive (auto-dismiss 6s)* to see the pinned 6s; click *Fire
time-sensitive, no auto-dismiss* to see it sit there forever, which is the same
finding from the other side.

**What I could not verify:** that the banner *pixels* actually vanish when
`removeDeliveredNotifications` is called on a currently-visible alert. I can
prove the store is cleared; only David can confirm the screen follows. (This
process has no way to screenshot a notification — experiment 9 already found
that `screencapture` without Screen Recording permission returns wallpaper with
all windows omitted.)

## Gotchas collected

- **No bundle id → hard trap.** `UNUserNotificationCenter.current()` does not
  return nil or throw; it kills the process. `swift run` alone can never work.
- **The permission prompt blocks `requestAuthorization` forever** until
  answered, so anything sequenced after that `await` silently never executes.
  This is why the code dumps notification settings *before* requesting, not
  only after — the first version's entire settings dump vanished into the
  pending prompt.
- **Killing the app while the prompt is up = denial**, and denial is sticky.
- **`open` does forward the calling shell's environment** to the launched app —
  `EXP13_LOG` and `EXP13_AUTOFIRE` arrive intact, which is what makes
  `artifacts/run.log` exist at all.
- **Top-level `func`s are not `@MainActor`** even though top-level *variables*
  and statements are; two build errors came from exactly that asymmetry.

## Recommendation for BrightspaceBar

Notifications can carry the MFA code, but `.timeSensitive` is not available to
us without a paid developer account and a provisioning profile. The realistic
options, cheapest first:

1. **Ask David to allowlist BrightspaceBar in his Focus** (System Settings →
   Focus → Apps). Free, one-time, and works with an ordinary `.active`
   notification.
2. **Don't use a notification at all.** The status item is already on screen and
   under our control — showing the 2-digit code *in the menu-bar item itself*
   bypasses the entire Focus question. Given that experiment 12 is already
   about the status item, this is probably the better vertical.
3. Buy the entitlement (developer account + profile) — most expensive, and it
   still only helps if Apple's review grants the capability.
