# Experiments

Numbered engineering probes that de-risked the app's design decisions — each folder is self-contained with its own README and verdict.

| # | Name | Question it answered |
|---|------|----------------------|
| 1 | [experiment-1-fresh-cookie](experiment-1-fresh-cookie/) | Can a headed Entra SSO login mint a fresh Brightspace session cookie? |
| 2 | [experiment-2-cookie-to-jwt](experiment-2-cookie-to-jwt/) | Can a session cookie + XSRF token mint a JWT and call the Valence API with pure HTTP (no browser)? |
| 3 | [experiment-3-etag-probe](experiment-3-etag-probe/) | Does Brightspace support HTTP conditional requests (`If-None-Match` → `304`) for cheap polling? |
| 4 | [experiment-4-course-pipeline](experiment-4-course-pipeline/) | Can everything between "we have a JWT" and "a menu could render this" be built GUI-free in Swift? |
| 5 | [experiment-5-menubar](experiment-5-menubar/) | Can the thin vertical land its last mile — a macOS menu bar icon that shows your classes? |
| 6 | [experiment-6-ended-course-access](experiment-6-ended-course-access/) | Does the API gate ended courses like the UI? (Verdict: API_LOCKED — 403 on all content routes) |
| 7 | [experiment-7-assignment-deeplinks](experiment-7-assignment-deeplinks/) | Can a per-assignment deep-link URL be built purely from ids the API already gives us? |
| 8 | [experiment-8-calendar-route](experiment-8-calendar-route/) | Does the calendar route yield assignment due dates? (Verdict: CALENDAR_EMPTY — keep dropbox/folders) |
| 9 | [experiment-9-custom-menu-item](experiment-9-custom-menu-item/) | Can a custom-rendered `NSMenuItem` give hover unity (title + graph as one component), and at what cost? |
| 10 | [experiment-10-entra-silent-sso](experiment-10-entra-silent-sso/) | Can a persistent Entra session silently mint D2L sessions without re-login? |
| 11 | [experiment-11-totp-availability](experiment-11-totp-availability/) | Does Purdue's tenant permit registering a TOTP method (the path to zero-touch auth)? |
| 12 | [experiment-12-status-item-flip](experiment-12-status-item-flip/) | Can the status item itself display the MFA number-matching code with zero interaction? |
| 13 | [experiment-13-time-sensitive-notification](experiment-13-time-sensitive-notification/) | Can a time-sensitive macOS notification carry the MFA code through Do Not Disturb for exactly 6 seconds? |
| 14 | [experiment-14-haptic-strum](experiment-14-haptic-strum/) | Can haptic ticks at cell-boundary crossings make the hover sweep feel bodily-continuous? |
| 15 | [experiment-15-speed-afterglow](experiment-15-speed-afterglow/) | Can the sweep gain a skill — a fading comet tail earned only by moving fast enough? |
| 16 | [experiment-16-today-pulse](experiment-16-today-pulse/) | Can the today cell breathe (a slow outline pulse) without breaking the grid's calm-until-touched rule? |
| 17 | [experiment-17-mfa-icon-watch](experiment-17-mfa-icon-watch/) | How fast does the menu bar icon learn about `cache/mfa.json` written mid-login? |
| 18 | [experiment-18-refresh-countdown](experiment-18-refresh-countdown/) | Can the dropdown show a "Refreshes in N min" countdown that is correct at menu-open time, with no ticking timer? |
| 19 | [experiment-19-click-through-chromium](experiment-19-click-through-chromium/) | Do deep links opened in the daemon's signed-in Chromium land with no login, and how fast does it feel? |
