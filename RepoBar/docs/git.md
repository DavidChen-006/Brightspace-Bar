---
summary: "Local git actions, sync behavior, and fetch cadence for RepoBar menus."
read_when:
  - Adding or changing local git actions (sync/rebase/reset/branch/worktree)
  - Adjusting local fetch cadence or notifications
  - Debugging local state in repo submenus
---

# Local Git Actions

RepoBar surfaces local git state inside each repo submenu and exposes a set of actions.

## Where it appears
- Repo submenu → **Local State** block (view-based menu item).
- Branch/worktree switch submenus live directly under the same repo submenu.

## Auto fetch + auto sync
- **Fetch cadence** is configurable in Settings → Advanced → Local Projects → Fetch interval.
- Default interval: **5 minutes**.
- Fetch runs as `git fetch --prune` for repos that are refreshed and past the interval.
- Auto-sync (if enabled) still uses fast-forward only pulls for clean repos.

## Notifications
- Any successful sync action triggers a local user notification.
- Auto-sync and manual sync both use the same notification path.

## Local State block content
- Branch, sync state (ahead/behind/diverged/dirty), worktree name (if any).
- Upstream tracking branch (when configured).
- Dirty summary (`+ / - / ~` counts).
- Last fetch age (when known).
- Dirty file list (up to 10 entries).

## Actions
- **Sync**: `git fetch --prune` → `git pull --rebase --autostash` if behind → `git push` if ahead.
- **Rebase**: `git fetch --prune` → `git rebase --autostash @{u}` (requires clean working tree).
- **Reset**: `git fetch --prune` → `git reset --hard @{u}` (destructive; confirmation required).
- **Finder / Terminal**: open local path using the preferred terminal.
- **Checkout**: `git clone <host>/<owner>/<name>.git` into the local projects folder (opens Finder on success).

## Branch + Worktree switching
- **Branch switch**: `git switch <branch>`.
- **Worktree switch**: sets the preferred local worktree path for that repo so the menu highlights that path next refresh.
- If switching fails, show an alert and abort.

## Worktree defaults
- New worktrees are created under the configured worktree folder (default `.work`).
