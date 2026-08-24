# Local App → Community-Ready GitHub Repo Checklist

## 1. Freeze the working local version

Before cleaning anything up, make sure I have a known-good version.

- [ ] App runs successfully from a clean restart
- [ ] Core happy path works
- [ ] Existing tests pass
- [ ] Build succeeds
- [ ] Record the exact runtime/toolchain versions I am using
- [ ] Commit the known-working state before doing open-source cleanup

**Goal:** Don't accidentally turn "make it open source" into a giant refactor.

---

## 2. Remove everything that must never become public

This is the first serious GitHub check.

- [ ] Remove API keys
- [ ] Remove passwords
- [ ] Remove access tokens
- [ ] Remove private certificates / SSH keys
- [ ] Remove `.env`
- [ ] Remove production database credentials
- [ ] Remove private URLs/endpoints
- [ ] Remove customer/user data
- [ ] Remove internal logs containing sensitive information
- [ ] Check git history for secrets, not just the current files
- [ ] Rotate any secret that was ever committed

Create something like:

```text
.env.example
```

with placeholders:

```text
DATABASE_URL=
OPENAI_API_KEY=
APP_SECRET=
```

---

## 3. Clean the repository boundary

Decide what actually belongs in source control.

- [ ] Create/update `.gitignore`
- [ ] Ignore dependencies such as `node_modules/`
- [ ] Ignore build artifacts
- [ ] Ignore caches
- [ ] Ignore local databases
- [ ] Ignore IDE-specific files unless intentionally shared
- [ ] Ignore OS junk such as `.DS_Store`
- [ ] Ignore `.env`
- [ ] Remove generated files that can be regenerated
- [ ] Remove random experiments/scratch files
- [ ] Remove giant binaries that do not belong in Git

I want:

```text
git clone
↓
install
↓
configure
↓
run
```

—not "clone my entire laptop."

---

## 4. Make setup reproducible

This is usually the biggest difference between a **personal project** and a **real open-source project**.

- [ ] Declare every dependency
- [ ] Pin or constrain important dependency versions
- [ ] Declare runtime version
- [ ] Declare system dependencies
- [ ] Include lockfiles
- [ ] Remove dependencies on files outside the repository
- [ ] Remove dependencies on my personal filesystem paths
- [ ] Make environment variables explicit
- [ ] Add setup scripts where useful
- [ ] Make database initialization reproducible
- [ ] Make migrations reproducible
- [ ] Add seed/sample data if needed

Examples:

```text
package.json
package-lock.json

pyproject.toml
uv.lock

Cargo.toml
Cargo.lock

go.mod
go.sum
```

If the project requires special infrastructure:

- [ ] Add `docker-compose.yml`, Dockerfile, Nix config, Dev Container, or equivalent if it materially simplifies setup

---

## 5. Test the "stranger clone"

This is one of my most important checks.

Pretend I am somebody who has never seen the project.

Ideally test in:

- [ ] Fresh directory
- [ ] Fresh user account
- [ ] Container
- [ ] VM
- [ ] Another computer

Then literally do:

```bash
git clone <repo>
cd <repo>
<installation commands>
<run command>
```

Check:

- [ ] Nothing depends on my home directory
- [ ] Nothing depends on an uncommitted config
- [ ] Nothing depends on software I forgot to document
- [ ] Nothing depends on my existing database
- [ ] Nothing depends on cached state
- [ ] App actually starts

**Rule:** If a stranger cannot reproduce it, it isn't really open source yet.

---

## 6. Give the repository an understandable structure

Before asking people to contribute, I want someone to understand the repo without reading every file.

- [ ] Remove obviously dead code
- [ ] Give important folders meaningful names
- [ ] Separate application code from tooling/config
- [ ] Identify entry points clearly
- [ ] Avoid unnecessarily clever structure
- [ ] Document unusual architecture decisions

A typical repo might look like:

```text
project/
├── src/
├── tests/
├── docs/
├── scripts/
├── examples/
├── .github/
├── .env.example
├── README.md
├── CONTRIBUTING.md
├── LICENSE
└── CHANGELOG.md
```

Not every project needs every folder.

---

## 7. Write the README from a newcomer's perspective

The README is the project's front door.

- [ ] One-sentence explanation of what the project does
- [ ] Screenshot/demo if visual
- [ ] Explain why the project exists
- [ ] List major features
- [ ] State project maturity/status
- [ ] Show prerequisites
- [ ] Show installation
- [ ] Show configuration
- [ ] Show the shortest possible run command
- [ ] Include a minimal usage example
- [ ] Explain where documentation lives
- [ ] Link contribution instructions
- [ ] State license

The first few sections should answer:

```text
What is this?
↓
Why would I use it?
↓
How do I run it?
```

A newcomer should not need an architecture lesson before seeing the application work.

---

## 8. Make failure understandable

A setup command failing with:

```text
Error: ECONNREFUSED
```

is much worse than:

```text
Database unavailable.
Start PostgreSQL with:
docker compose up db
```

Check:

- [ ] Missing environment variables produce useful errors
- [ ] Missing dependencies produce useful errors
- [ ] Invalid configuration fails early
- [ ] Database failures explain what needs to be running
- [ ] Setup failures don't produce mysterious stack traces where avoidable
- [ ] Example config is kept synchronized with actual config

---

## 9. Establish tests contributors can trust

I don't necessarily need enormous coverage before publishing.

I do need enough tests to protect the project's important invariants.

- [ ] Unit tests for core logic
- [ ] Integration tests for important boundaries
- [ ] At least one smoke/happy-path test
- [ ] Regression tests for important bugs
- [ ] Tests can run with one documented command
- [ ] Tests do not depend on my machine
- [ ] Tests are reasonably deterministic

Ideally:

```bash
make test
```

or:

```bash
npm test
```

or:

```bash
uv run pytest
```

---

## 10. Automate the checks with CI

Anything I expect contributors to remember manually will eventually be forgotten.

Set up GitHub Actions or equivalent.

- [ ] Install dependencies from scratch
- [ ] Run formatter check
- [ ] Run linter
- [ ] Run type checker if applicable
- [ ] Run tests
- [ ] Build the application
- [ ] Run migrations/check migration validity if relevant
- [ ] Fail PRs when required checks fail

Conceptually:

```text
PR
 ↓
Install
 ↓
Lint
 ↓
Typecheck
 ↓
Test
 ↓
Build
 ↓
Merge
```

A contributor should know whether their change is acceptable without me manually checking everything.

---

## 11. Standardize formatting and linting

Remove arguments that computers can settle automatically.

- [ ] Choose formatter
- [ ] Choose linter
- [ ] Commit configuration
- [ ] Add commands to README/CONTRIBUTING
- [ ] Run them in CI
- [ ] Optionally add pre-commit hooks

Examples:

```text
Prettier
ESLint
Ruff
Black
Clippy
gofmt
golangci-lint
```

---

## 12. Add a license

Without a license, "it's on GitHub" does **not** automatically mean people have permission to reuse it.

- [ ] Choose license intentionally
- [ ] Add `LICENSE`
- [ ] Mention it in README
- [ ] Verify dependencies are license-compatible

Common choices:

```text
MIT
Apache-2.0
GPL-3.0
AGPL-3.0
```

For many small permissive open-source projects, MIT or Apache-2.0 are common choices.

---

## 13. Write CONTRIBUTING.md

Now I explain how another engineer joins the development loop.

- [ ] How to set up the development environment
- [ ] How to run the project
- [ ] How to run tests
- [ ] How to lint/format
- [ ] Branch expectations
- [ ] Commit expectations if any
- [ ] PR expectations
- [ ] Where architecture documentation lives
- [ ] How to report bugs
- [ ] How to propose features

The contribution loop should be obvious:

```text
Fork/clone
  ↓
Create branch
  ↓
Make change
  ↓
Test
  ↓
Commit
  ↓
Open PR
```

---

## 14. Define the contribution boundary

This matters more than people realize.

A contributor needs to know:

> "What kinds of changes would the maintainer actually accept?"

- [ ] State the project's scope
- [ ] State major non-goals
- [ ] Explain whether large features need discussion first
- [ ] Identify intentionally stable APIs
- [ ] Identify experimental areas
- [ ] Document architectural constraints that contributors shouldn't casually break

Otherwise people can spend days making a technically good PR that doesn't fit the project.

---

## 15. Add GitHub issue templates

Make incoming information structured enough to act on.

### Bug report

- [ ] What happened?
- [ ] What should have happened?
- [ ] Reproduction steps
- [ ] Version/commit
- [ ] OS/environment
- [ ] Logs/screenshots

### Feature request

- [ ] Problem being solved
- [ ] Proposed behavior
- [ ] Alternatives
- [ ] Additional context

Avoid a template so bureaucratic that nobody wants to file an issue.

---

## 16. Add a pull request template

I usually want contributors answering things like:

- [ ] What does this change?
- [ ] Why is it needed?
- [ ] How was it tested?
- [ ] Does it introduce a breaking change?
- [ ] Are docs needed?
- [ ] Are migrations needed?

The goal isn't bureaucracy.

The goal is making review cheap.

---

## 17. Protect the main branch

Once outsiders are contributing:

- [ ] Require PRs before merging
- [ ] Require CI
- [ ] Prevent accidental force pushes
- [ ] Prevent accidental branch deletion
- [ ] Optionally require review
- [ ] Optionally require branch to be up to date before merge

`main` should represent:

> "This is believed to work."

---

## 18. Make the architecture discoverable

You do **not** need a 100-page architecture document.

You do need enough orientation that contributors know where to look.

- [ ] Explain top-level components
- [ ] Explain major data flow
- [ ] Explain important boundaries
- [ ] Explain persistence layer
- [ ] Explain external services
- [ ] Explain configuration system
- [ ] Explain unusual design decisions

A short map is extremely valuable:

```text
User
 ↓
Frontend
 ↓
API
 ↓
Application/Domain Logic
 ↓
Database

        ↘ External Service
```

Then map folders onto those concepts.

---

## 19. Create "good first issues"

Do not invite contributors and then give them nothing tractable to do.

Find tasks that:

- [ ] Have low architectural risk
- [ ] Require limited context
- [ ] Have a clear expected result
- [ ] Can be tested
- [ ] Still provide meaningful value

Examples:

```text
Improve error message
Add test for parser edge case
Document setup on Linux
Add missing CLI flag
Fix small UI bug
Add example
```

Label them:

```text
good first issue
help wanted
documentation
bug
enhancement
```

---

## 20. Test the contributor workflow yourself

Now simulate an actual contribution.

From a clean clone:

```bash
git clone ...
git checkout -b test-contribution

# make trivial change

<format>
<lint>
<test>
<build>

git commit
git push
```

Then open a PR.

Verify:

- [ ] PR template appears
- [ ] CI starts automatically
- [ ] Checks are understandable
- [ ] Contribution instructions are correct
- [ ] Nothing requires undocumented knowledge
- [ ] A contributor can tell why CI failed

---

## 21. Clean up GitHub repository metadata

- [ ] Good repository name
- [ ] Short description
- [ ] Relevant topics/tags
- [ ] Website/demo link if available
- [ ] README renders correctly
- [ ] License detected correctly
- [ ] Issues enabled
- [ ] Discussions enabled if useful
- [ ] Wiki disabled if unused
- [ ] Repository visibility correct
- [ ] Default branch correct

---

## 22. Establish release/versioning conventions

Once users depend on the project, changes acquire consequences.

- [ ] Decide versioning scheme
- [ ] Tag releases
- [ ] Create release notes
- [ ] State breaking changes clearly
- [ ] Keep changelog if useful
- [ ] Automate package/release publishing if appropriate

Commonly:

```text
v0.1.0
v0.2.0
v1.0.0
```

I treat `0.x` as a useful signal that the project/API is still evolving.

---

## 23. Check dependency/security hygiene

- [ ] Remove unused dependencies
- [ ] Check for known vulnerabilities
- [ ] Enable Dependabot/Renovate if useful
- [ ] Pin GitHub Action versions appropriately
- [ ] Avoid unnecessarily privileged CI tokens
- [ ] Don't expose secrets to untrusted PRs
- [ ] Review install scripts for dangerous assumptions
- [ ] Set sensible dependency-update policy

---

## 24. Ask the final newcomer questions

Before announcing the project, I ask:

- [ ] Can somebody understand what this project is in 30 seconds?
- [ ] Can somebody get it running without messaging me?
- [ ] Can somebody discover where the code they want to change lives?
- [ ] Can somebody know whether their change works?
- [ ] Can somebody know whether I would accept their change?
- [ ] Can somebody open a useful issue without knowing me?
- [ ] Can somebody open a PR and get meaningful automated feedback?
- [ ] Can I review that PR without reconstructing their environment?

If those answers are **yes**, the repository is probably community-ready.

---

# My actual workflow condensed

```text
Working local app
        ↓
Commit known-good state
        ↓
Remove secrets/private data
        ↓
Define .gitignore
        ↓
Make dependencies reproducible
        ↓
Fresh-clone test
        ↓
Clean repository structure
        ↓
README + .env.example
        ↓
Tests
        ↓
Formatter / linter / typecheck
        ↓
GitHub Actions CI
        ↓
LICENSE
        ↓
CONTRIBUTING.md
        ↓
Architecture overview
        ↓
Issue + PR templates
        ↓
Branch protection
        ↓
Good first issues
        ↓
Simulate outsider PR
        ↓
Publish / announce
```

## The standard I use

I don't consider a project truly **open-source ready** merely because the code is public.

I consider it ready when this loop works:

```text
STRANGER
   ↓
git clone
   ↓
understands project
   ↓
gets it running
   ↓
finds something to change
   ↓
makes change
   ↓
runs checks locally
   ↓
opens PR
   ↓
CI independently verifies it
   ↓
maintainer can review it
   ↓
MERGE
```

That is the transition from **"my code is on GitHub"** to **"this is an open-source project other engineers can actually participate in."**
