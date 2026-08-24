# Orchestrator Instructions

Your role is **the orchestrator**.

You are **not writing code yourself**. Your responsibility is to coordinate sub-agents, manage dependencies, provide context, and ensure the overall architecture is implemented correctly.

Before executing anything, keep these design principles in mind:

- We have already designed the overall architecture.
- We have already separated:
  - pure logic
  - side effects
- Most of the required components already exist.
- The remaining work is primarily:
  - piecing the components together
  - following the existing coding philosophy
  - verifying correctness through tests.

The most important part is **how we design our tests** and verify that the implementation is correct.

---

# High-Level Plan

Think of this work as **three spikes (or three challenges).**

They form a dependency graph:

```
                Design Interface
                       │
         ┌─────────────┴─────────────┐
         │                           │
     GUI Spike                 Backend Spike
         │                           │
         └─────────────┬─────────────┘
                       │
                 Final Wiring
```

The dependency order is:

1. Design the interface.
2. Split into two parallel jobs:
   - Frontend (GUI)
   - Backend
3. Merge both into one final wiring step.

---

# General Rules

Every challenge should use sub-agents.

In general:

- Every **builder** should spawn the **Code Writer** skill.
- Every **tester** should spawn the **Test Writer** skill.

The only exception is the first interface-design phase, where a separate tester is unnecessary.

Also:

- Do **all work inside the actual Brightspace Bar codebase**.
- Do **not** create a new experiment folder anymore.
- Spawn the implementation sub-agent in **Opus 5 High** mode (or the highest mode available).

---

# Challenge 1 — Design the Interface

This is the first dependency.

The vertical slice is:

```
Get assignments
      ↓
Pass assignment data
      ↓
GUI displays submenu
      ↓
Links are clickable
```

The interface needs to define exactly what the backend provides to the GUI.

You will likely need to search the codebase and understand how the backend currently works.

At minimum, the interface needs to include:

- assignment name
- due date
- assignment URL

There may be additional fields, but those three are essential.

After designing the interface:

- write a simple verification test
- the goal is only to prove information can pass through the interface correctly
- nothing complex is needed

This is just validating that one side can pass data to the other.

---

# Parallel Challenge 1 — GUI Spike

After the interface exists, begin the GUI work.

The GUI should **not** depend on the backend yet.

Instead:

- build the submenu
- make it clickable
- display **stubbed data**

The assignment names should simply be fake seeded data.

The purpose is to prove:

- layout works
- submenu works
- clicking works

The fake assignments become **seams**.

Later, those seams will be replaced by real backend data.

The philosophy is:

```
Build the interface first.

Then build from both ends simultaneously.

Finally wire them together.
```

---

## GUI Development Flow

1. Spawn a **Test Writer** sub-agent.

2. Write an end-to-end happy path test for the macOS menu bar GUI.

3. The test should initially fail (red).

4. Spawn the **Builder** (which uses the Code Writer skill).

5. Build the GUI using stubbed data.

6. Pass the test (green).

---

# Parallel Challenge 2 — Backend Spike

The backend architecture has already been discussed.

The builder should already know the intended architecture.

The focus here is verifying behavior through end-to-end tests.

Use my actual Brightspace course as the test fixture.

That course currently has the four null assignments.

That becomes the end-to-end verification.

---

## Backend Test

The end-to-end test should verify the entire backend pipeline:

```
Course data
      ↓
Parse courses
      ↓
Loop through every course
      ↓
Find assignments
      ↓
Extract assignment information
```

For every assignment, verify at least:

- assignment URL
- due date
- assignment name

Those three fields are the contract.

The URL will ultimately be hidden in the GUI, but it still needs to be passed through the interface.

---

## Backend Development Flow

1. Spawn the **Test Writer** skill.

2. Write the complete end-to-end test.

3. Test begins red.

4. Spawn the Builder.

5. Implement the architecture.

6. Test becomes green.

As the orchestrator, your responsibility is giving these agents enough context.

Consider spawning them as **forked sub-agents** so they maintain isolated context while still receiving the architectural guidance they need.

---

# Final Challenge — Wiring Everything Together

This stage cannot begin until:

- GUI spike is complete
- Backend spike is complete

Now create a sub-agent whose sole responsibility is wiring everything together.

Its job is connecting:

```
Backend
    ↓
Interface
    ↓
GUI
```

The stubbed GUI seams should now be replaced by real backend data.

---

## Final End-to-End Test

Write one complete end-to-end happy path.

The flow should be:

```
Course data
      ↓
Backend parsing
      ↓
Assignment extraction
      ↓
Interface
      ↓
GUI
      ↓
Real submenu
      ↓
Clickable assignment links
```

The test should initially fail (red).

Then:

1. Spawn the Builder.
2. Wire everything together.
3. Test passes (green).

---

# Project Structure Requirements

Follow the existing project organization exactly.

Specifically:

- follow the existing folder structure
- follow the existing module structure
- stay consistent with the current architecture

If new functionality is required:

- prefer creating a **new module**
- avoid adding unrelated functionality to existing modules

I prefer highly modular code so every module has a single, obvious responsibility.

