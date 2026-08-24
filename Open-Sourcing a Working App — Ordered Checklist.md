# Open-Sourcing a Working App — Ordered Checklist

## Phase 1 — Freeze the Working Baseline

- [x] **1. Confirm the app actually works locally**
  - Start from a clean restart.
  - Test the main user flow.
  - Make sure you know the exact commands required to run it.

- [x] **2. Commit the known-good local version**
  - Get to a clean `git status`.
  - Make one baseline commit before doing open-source cleanup.
  - Tag it mentally as: *this is the version that worked before I touched packaging/docs.*

- [ ] **3. Identify everything the app depends on**
  - Runtime/language version.
  - Package manager.
  - Database.
  - External APIs.
  - Environment variables.
  - System packages.
  - Background workers/services.
  - Build tools.

---

## Phase 2 — Remove Everything That Should Never Be Public

- [x] **4. Search the entire repo for secrets**
  - API keys.
  - Tokens.
  - Passwords.
  - Database credentials.
  - Private URLs.
  - SSH keys.
  - `.env` contents.
  - Cloud credentials.
  - Test credentials containing real accounts.

- [ ] **5. Rotate anything that was previously committed**
  - Deleting a secret from the current file is not enough if it exists in Git history.
  - Revoke/rotate exposed credentials.

- [x] **6. Create or audit `.gitignore`**
  - `.env`
  - dependency directories such as `node_modules/`
  - build outputs
  - caches
  - IDE files
  - OS files
  - logs
  - local databases
  - generated artifacts
  - temporary files

- [x] **7. Remove personal/local-machine assumptions**
  - `/Users/yourname/...`
  - absolute paths.
  - localhost ports hardcoded unnecessarily.
  - usernames.
  - machine-specific directories.
  - references to your personal accounts.

---

## Phase 3 — Make the Environment Reproducible

- [ ] **8. Pin the important runtime versions**
  - Node/Python/Rust/Go/etc.
  - Record the supported version somewhere machine-readable when possible.

- [ ] **9. Make dependencies declarative**
  - `package.json`
  - `pyproject.toml`
  - `requirements.txt`
  - `Cargo.toml`
  - `go.mod`
  - etc.

- [ ] **10. Commit the appropriate lockfile**
  - `package-lock.json`
  - `pnpm-lock.yaml`
  - `yarn.lock`
  - `uv.lock`
  - `poetry.lock`
  - `Cargo.lock`
  - etc.

- [ ] **11. Create `.env.example`**
  - Include every required environment variable.
  - Put fake/example values in it.
  - Explain unusual variables.
  - Never put real credentials in it.

- [ ] **12. Make first-time setup deterministic**
  - A new contributor should not need knowledge that exists only in your head.
  - Ideally setup becomes a handful of commands.

- [x] **13. Add bootstrap/setup scripts where useful**
  - Example:
    ```bash
    ./scripts/setup.sh
    ```
  - Or:
    ```bash
    make setup
    ```

- [ ] **14. Make database setup reproducible**
  - Schema migrations.
  - Seed data if required.
  - Commands for creating/resetting a development DB.
  - No dependency on your existing local database.

---

## Phase 4 — Test the Repo From a Stranger's Perspective

- [ ] **15. Clone the project into a completely new directory**
  - Do not test only from your original development folder.

- [ ] **16. Follow only the instructions you intend to publish**
  - Pretend you know nothing about the project.
  - Do not use undocumented commands from memory.

- [ ] **17. Verify installation from zero**
  - Install dependencies.
  - Configure environment variables.
  - Set up the DB.
  - Build.
  - Start the app.

- [ ] **18. Verify the main user flow**
  - The app should actually perform its primary purpose.

- [ ] **19. Run the complete test suite**
  ```bash
  npm test
  # or
  pytest
  # etc.
  ```

- [ ] **20. Run linting, formatting and type checking**
  - Linter.
  - Formatter.
  - Static type checker.
  - Compiler/build checks.

---

## Phase 5 — Clean the Repository Structure

- [x] **21. Make the top-level directory understandable**
  - Avoid a dump of random scripts/files.
  - Typical structure:
    ```text
    project/
    ├── src/
    ├── tests/
    ├── docs/
    ├── scripts/
    ├── examples/
    ├── .github/
    ├── README.md
    └── LICENSE
    ```

- [x] **22. Delete abandoned experiments**
  - `test2.py`
  - `old_server.js`
  - `final_final_v3`
  - unused prototypes.
  - commented-out implementations.

- [ ] **23. Remove dead dependencies**
  - If the app no longer imports it, don't make contributors install it.

- [x] **24. Standardize project commands**
  - Contributors should have obvious commands such as:
    ```bash
    make dev
    make test
    make lint
    make build
    ```

- [ ] **25. Separate generated files from source files**
  - Contributors should know what they are expected to edit.

---

## Phase 6 — Establish the Project's Public Contract

- [x] **26. Choose a license**
  - MIT.
  - Apache-2.0.
  - GPL.
  - AGPL.
  - etc.
  - Add `LICENSE` to the repository.

- [ ] **27. Decide what the project officially supports**
  - Operating systems.
  - Runtime versions.
  - Databases.
  - Browsers.
  - Deployment environments.

- [ ] **28. Mark experimental versus stable APIs**
  - Contributors should know what they can safely build against.

- [ ] **29. Define backwards-compatibility expectations**
  - Particularly important for libraries, SDKs, CLIs and APIs.

---

## Phase 7 — Write the README

- [ ] **30. Explain what the project is immediately**
  - First paragraph should answer:
    > What does this do and why would I use it?

- [ ] **31. Show the project**
  - Screenshot.
  - GIF.
  - Demo.
  - CLI example.
  - API example.

- [ ] **32. Add a minimal Quick Start**
  ```bash
  git clone ...
  cd project
  ...
  ```

- [ ] **33. Document prerequisites**
  - Runtime version.
  - Database.
  - Docker if required.
  - External accounts/APIs.

- [ ] **34. Document environment configuration**

- [ ] **35. Document how to start development mode**

- [ ] **36. Document how to run tests**

- [ ] **37. Document how to build the project**

- [ ] **38. Explain the basic architecture**
  - Give contributors a map before making them read thousands of lines of code.

- [ ] **39. Link to deeper documentation instead of turning the README into a book**

---

## Phase 8 — Make Contribution Possible

- [x] **40. Create `CONTRIBUTING.md`**

- [ ] **41. Explain contributor setup**
  - Fork.
  - Clone.
  - Install.
  - Configure.
  - Run.
  - Test.

- [ ] **42. Explain the contribution workflow**
  ```text
  Issue
    ↓
  Branch
    ↓
  Implementation
    ↓
  Tests
    ↓
  Pull Request
    ↓
  CI
    ↓
  Review
    ↓
  Merge
  ```

- [ ] **43. Define branch naming if you care about it**

- [ ] **44. Define formatting/lint expectations**

- [ ] **45. Define testing expectations**
  - Bug fix → regression test.
  - New behavior → tests.
  - Large architecture changes → discuss first.

- [ ] **46. Explain how commits/PRs should be scoped**
  - Prefer small, focused changes.
  - Avoid unrelated cleanup mixed into feature PRs.

- [ ] **47. Tell contributors when they should open an issue before coding**
  - Especially for large features or architectural changes.

---

## Phase 9 — Make the Architecture Legible

- [ ] **48. Create a short architecture document**
  - Usually `docs/architecture.md`.

- [ ] **49. Explain the major components**
  ```text
  Client
    ↓
  API
    ↓
  Application/service layer
    ↓
  Database
  ```

- [ ] **50. Explain the important data flow**

- [ ] **51. Explain important invariants**
  - These are often more useful than explaining every class.

- [ ] **52. Explain extension points**
  - Where would someone add:
    - a provider?
    - command?
    - route?
    - model?
    - integration?
    - plugin?

- [ ] **53. Document intentionally strange decisions**
  - If a contributor will look at code and think:
    > Why did they do it this way?
  - Write down the answer.

---

## Phase 10 — Put Quality Checks Into Automation

- [ ] **54. Add GitHub Actions CI**

- [ ] **55. Run tests on every pull request**

- [ ] **56. Run linting on every pull request**

- [ ] **57. Run type checking/compiler checks**

- [ ] **58. Run the build**

- [ ] **59. Test the supported runtime versions if appropriate**

- [ ] **60. Make CI failures understandable**
  - A contributor should know what they need to fix.

- [ ] **61. Require CI to pass before merging**

---

## Phase 11 — Prepare GitHub Itself

- [ ] **62. Add a good repository description**

- [ ] **63. Add relevant GitHub topics**

- [x] **64. Create issue templates**
  - Bug report.
  - Feature request.

- [ ] **65. Create a pull request template**
  - What changed?
  - Why?
  - How was it tested?
  - Screenshots if applicable.

- [ ] **66. Add `CODE_OF_CONDUCT.md` if you expect a community**

- [ ] **67. Add `SECURITY.md`**
  - Explain how security vulnerabilities should be reported privately.

- [ ] **68. Configure Dependabot/Renovate if useful**

- [ ] **69. Configure branch protection**
  - Require PRs.
  - Require CI.
  - Prevent accidental force pushes to `main`.

---

## Phase 12 — Seed the Contributor Experience

- [ ] **70. Create several real GitHub issues yourself**
  - Don't launch with an empty Issues tab.

- [ ] **71. Label issues**
  - `bug`
  - `enhancement`
  - `documentation`
  - `good first issue`
  - `help wanted`

- [ ] **72. Create genuinely small `good first issue`s**
  - They should require understanding a small portion of the codebase.

- [ ] **73. Write unusually good issue descriptions**
  - Current behavior.
  - Desired behavior.
  - Relevant files.
  - Acceptance criteria.
  - Reproduction steps when relevant.

- [ ] **74. Test one issue yourself using the public contribution instructions**
  - Can someone discover the problem, make the change and verify it without hidden knowledge?

---

## Phase 13 — Perform the "Fresh Contributor" Test

- [ ] **75. Delete or move your test clone**

- [ ] **76. Clone the public-style repo again**

- [ ] **77. Time how much undocumented knowledge you need**
  - Every time you think:
    > Oh, I forgot—you also have to...
  - Stop and document or automate it.

- [ ] **78. Verify this path works**
  ```text
  git clone
      ↓
  install
      ↓
  configure
      ↓
  run
      ↓
  change something
      ↓
  test
      ↓
  open PR
  ```

- [ ] **79. Test on another machine/container if practical**
  - This catches environment assumptions that a second folder cannot.

---

## Phase 14 — Publish

- [ ] **80. Do one final secrets scan**

- [ ] **81. Run the entire CI-equivalent suite locally**

- [ ] **82. Push the repository to GitHub**

- [ ] **83. Verify the README renders correctly on GitHub**

- [ ] **84. Verify links and images work**

- [ ] **85. Verify a fresh GitHub clone still works**

- [ ] **86. Create the first release/tag if the project is ready for one**
  ```bash
  git tag v0.1.0
  git push origin v0.1.0
  ```

- [ ] **87. Write release notes**
  - What it does.
  - Known limitations.
  - What kind of contributions you want.

---

## Phase 15 — Operate It Like an Open-Source Project

- [ ] **88. Respond to the first issues quickly**

- [ ] **89. Review the first external PRs carefully but constructively**

- [ ] **90. Turn repeated contributor confusion into documentation**

- [ ] **91. Turn repeated review comments into automation**
  - Formatter.
  - Linter.
  - Test.
  - CI rule.
  - template.

- [ ] **92. Keep `main` healthy**
  - The community should be able to clone `main` and expect it to work.

- [ ] **93. Keep open issues reasonably groomed**

- [ ] **94. Make releases periodically**

- [ ] **95. Keep contributor setup working as the project evolves**

---

# The Core Test

Before I consider a repository truly open-source-ready, I ask:

> **Can a competent developer who has never spoken to me clone this repository, understand what it does, get it running, find a useful piece of work, make the change, prove that the change works, and submit a passing PR without needing information that exists only in my head?**

If the answer is **yes**, the app has made the transition from:

```text
software that works on my computer
```

to:

```text
software that a community can own with me
```