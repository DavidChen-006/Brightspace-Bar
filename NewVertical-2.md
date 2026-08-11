# Next Vertical Slice: Course Activity Graph

The next obvious vertical slice created by adding quizzes is the **graph**.

If you look at RepoBar, it has a GitHub-style activity graph. Brightspace Bar needs something similar.

The reason quizzes specifically force this next step is that students need some kind of calendar-like representation of upcoming work.

In this case, the calendar is essentially a **commit-history-style heatmap**:

- GitHub uses cells to represent commits.
- Brightspace Bar will use cells to represent assignments and quizzes.

This is important to build now because the code can already distinguish between:

- assignments
- quizzes

That distinction now needs to exist both:

1. in the code
2. visually in the GUI

That is exactly what the graph should represent.

---

# Core Goal

For every course in the main menu, display a GitHub-style activity graph underneath the course name.

The graph should visually represent upcoming course work based on:

- due date
- activity type
- current date

At minimum, we need to distinguish:

- assignments
- quizzes

For example:

- assignments → lighter cells
- quizzes → darker cells because they are more important

We also need to visually indicate **today's cell**.

---

# Initial Problem Decomposition

At first, this looks like two major problems:

```text
Frontend / GUI
Backend / Logic
```

However, they should **not** be developed in parallel yet.

The frontend implementation determines what data representation the graph actually needs.

Therefore, the dependency structure is sequential.

---

# RepoBar as the Reference Implementation

RepoBar already contains the custom graph-rendering code.

The GUI problem is therefore not primarily inventing a new graph.

The challenge is:

> How do we copy or adapt only the thinnest amount of RepoBar's graph code into Brightspace Bar?

Do **not** blindly copy the entire implementation.

We want the minimum amount of code required to reproduce the graph behavior.

If we copy or adapt unnecessary RepoBar functionality, we create unnecessary complexity and waste.

The goal is to determine:

- what rendering code is essential
- what supporting code is essential
- what RepoBar-specific behavior can be discarded

---

# Important Development Philosophy

Normally, I like to develop this way:

```text
API Contract
     ↓
 ┌───┴───┐
Frontend Backend
     ↓
   Wiring
```

The frontend can then use stubs and seams while the backend is being developed.

However, **this feature is different**.

We cannot design the API/interface intelligently until we understand exactly what the graph renderer expects.

Therefore, the GUI investigation has to happen first.

---

# Correct Dependency Graph

After working through the dependencies, the correct order is:

```text
1. Fake Course / Fake Data Environment
              ↓
2. Frontend Graph
              ↓
3. Interface / Schema
              ↓
4. Backend Mapping Logic
              ↓
5. Final Wiring + End-to-End Verification
```

This is a dependency graph that does **not** fan out.

Each step unlocks the next one.

---

# Dependency 1 — Build Accurate Fake Course Data

This is actually the first bottleneck.

My real Brightspace assignments and quizzes currently have `null` end dates.

Because of that, I cannot visually verify whether the graph is rendering assignments and quizzes correctly.

Therefore, we need a **fake course** with fake assignments and quizzes.

This fake data should include realistic examples with:

- course information
- assignment names
- quiz names
- due dates
- activity types
- URLs
- whatever additional fields the real Brightspace responses contain and the current parser depends on

The fake dataset should contain enough variety to visually verify the graph.

For example, it should include:

- multiple assignments
- multiple quizzes
- different due dates
- multiple events on different days
- possibly multiple events on the same day
- dates around today so the current-date indicator can be verified

---

# The Important Question: What Kind of Fake Is This?

We probably do **not** need a full fake database.

We are not testing persistence-heavy behavior.

This is mostly an **accuracy-of-input-data problem**.

We need to emulate the Brightspace data that the application consumes.

Therefore, the real question is:

> At what boundary should Brightspace be faked?

Possible approaches need to be evaluated.

This might be:

- fixture data
- a fake API response
- a network stub
- a mock Brightspace client
- a local HTTP fake
- another form of test double

Do **not** automatically introduce Docker, a database container, or other heavyweight infrastructure unless the architecture actually requires it.

Determine how a professional software engineer would fake this dependency while preserving the actual shape and behavior of Brightspace data.

Accuracy here matters enormously.

If the fake accurately represents the real Brightspace responses, everything downstream becomes much easier to trust.

If the fake is wrong or missing important details, the entire vertical slice can appear correct while actually being broken.

So treat this as the first major design problem.

---

# Dependency 2 — Frontend Graph

Once reliable fake course data exists, implement the graph underneath every course in the main menu.

Use RepoBar as the reference implementation.

The goal is initially to reproduce the graph visually with fake/stubbed information.

At this stage, we do **not** need real backend mapping yet.

We need to understand:

- how RepoBar's graph is rendered
- what data the renderer consumes
- how cells are indexed
- how dates correspond to cells
- how intensity/color is determined
- what the smallest reusable subset of RepoBar code is

Then create the Brightspace Bar version.

---

# Graph Placement

The graph should appear underneath each course name in the main menu.

Conceptually:

```text
Course A
[ ][ ][■][ ][□][ ][ ][...]

Course B
[ ][□][ ][ ][■][ ][ ][...]
```

The exact visual treatment should follow the existing RepoBar graph implementation as closely as makes sense while staying consistent with Brightspace Bar's existing GUI architecture.

---

# Today's Cell

The graph must clearly indicate **today**.

We need to know exactly which cell corresponds to the current date.

Do not use a filled dot or another marker that covers the cell's existing meaning.

For example, if today contains an assignment, a black dot could obscure the assignment state.

Instead, use something like an **outline / selection border** around the current day's cell.

Conceptually:

```text
normal cell:
[■]

today:
╔═╗
║■║
╚═╝
```

The important invariant is:

> The today indicator must not destroy or obscure the underlying activity state.

This means we need logic that reliably determines:

- today's date
- the graph's date range
- the cell corresponding to today

---

# Dependency 3 — Design the Interface / Schema

After the frontend graph exists, we will understand what the renderer actually needs.

Only then should we design the interface between backend and frontend.

This is probably the biggest architectural design problem.

The backend already knows things such as:

- assignment name
- due date
- assignment URL
- assignment vs quiz

Now we need a schema that maps those backend concepts efficiently onto the graph.

The interface should make it very easy for the frontend to answer:

```text
Which cell?
What activity?
How should it render?
```

The graph renderer and backend schema must coordinate cleanly.

We want the mapping to be simple and efficient rather than forcing the frontend to reconstruct complicated backend concepts.

---

# Activity Type / Tagging

Assignments and quizzes must be distinguishable.

The backend therefore needs some kind of tag or explicit type.

Conceptually:

```text
type = assignment
```

or:

```text
type = quiz
```

Then the renderer can decide how that type should appear.

For example:

```text
assignment → lighter intensity
quiz       → darker intensity
```

The important point is that the semantic distinction should exist in the data model rather than being inferred indirectly by the GUI.

---

# Backend Responsibility

The backend problem should remain relatively small.

We already know:

- the activity
- its date
- its type

Therefore, the backend mostly needs to derive the representation that the GUI needs.

This is primarily a **schema / mapping problem**.

The backend likely needs to produce enough information for the GUI to derive:

```text
date → graph location
type → visual treatment
```

Potentially the backend itself should derive some of this.

That architecture should be decided after understanding the frontend renderer.

---

# Pure Logic

This mapping should probably live in a focused pure-logic module.

At a conceptual level:

```text
Brightspace Activity
        ↓
   Pure Mapping
        ↓
 Graph Representation
```

Inputs might include:

- due date
- activity type
- graph date range

Outputs might include:

- cell/date location
- normalized activity type
- intensity/category

The exact boundary should follow the existing architecture.

Do not force this into an unrelated module.

If a new module gives the functionality a clearer responsibility, prefer a new module.

---

# Main Backend Question

The main backend problem is not simply implementing the mapping.

The important question is:

> How do we prove that the schema maps backend activity data correctly onto the frontend graph?

That means we need tests around the interface itself.

The important properties probably include:

- correct date maps to correct graph cell
- assignments map to assignment representation
- quizzes map to quiz representation
- today maps to the correct cell
- activity rendering does not interfere with today's indicator
- multiple dates map consistently
- whatever date boundaries RepoBar's graph uses are handled correctly

The exact test architecture should be designed after inspecting the graph renderer.

---

# Dependency 4 — Backend Mapping Logic

After the graph and interface are understood, implement the backend mapping.

The backend should take the parsed Brightspace activity information and generate whatever graph representation the interface specifies.

At minimum, the source information already includes:

```text
assignment / quiz
due date
name
URL
```

The graph-specific transformation is mostly about:

```text
date + type
      ↓
graph representation
```

Keep this logic as pure as practical.

Side effects should remain at the edges according to the architecture already established in the codebase.

---

# Dependency 5 — Wire Everything Together

Once:

- fake Brightspace data exists
- graph rendering works
- interface is defined
- backend mapping works

then replace the frontend seams/stubs with real mapped data.

The complete path becomes:

```text
Fake Brightspace Course Data
            ↓
Existing Brightspace Parsing
            ↓
Assignment / Quiz Domain Data
            ↓
Graph Mapping Logic
            ↓
Frontend Interface
            ↓
Graph Renderer
            ↓
Visible Course Activity Graph
```

---

# End-to-End Test

Somewhere during this sequence, create the end-to-end test.

The exact point should be chosen based on where it provides the most useful red → green development loop.

By the final stage, the end-to-end test needs to verify the complete vertical slice using the fake course data.

The final test should prove:

```text
Fake course data
      ↓
assignments + quizzes are parsed
      ↓
correct dates are derived
      ↓
correct activity types are retained
      ↓
activities map to correct graph cells
      ↓
assignment and quiz cells render differently
      ↓
today's cell is correctly outlined
      ↓
graph appears underneath the correct course
```

The test begins red.

After final wiring, it should become green.

---

# Verification Must Include Visual Verification

Because this is primarily a GUI feature, the test infrastructure should allow us to visually confirm the result.

The fake dataset should deliberately put events on known dates so we can know in advance what the graph should look like.

For example:

```text
Today              → Assignment
Tomorrow           → Quiz
Today + 3 days      → Assignment
Today + 5 days      → Quiz
```

Then the expected visual representation is deterministic.

This allows us to inspect the GUI and immediately know whether:

- today is positioned correctly
- assignments are positioned correctly
- quizzes are positioned correctly
- visual distinctions are correct

---

# Why the Fake Data Is the First Bottleneck

The fake course data is the foundation for the entire feature.

If the fake accurately models Brightspace, then:

```text
accurate fake
    ↓
reliable frontend development
    ↓
reliable interface design
    ↓
reliable backend mapping
    ↓
reliable E2E verification
```

If the fake is inaccurate:

```text
bad fake
   ↓
incorrect assumptions
   ↓
incorrect schema
   ↓
incorrect backend mapping
   ↓
tests can pass while production is broken
```

Therefore, spend real effort deciding the correct test-double boundary.

Do not simply invent an arbitrary JSON object that happens to make the GUI work.

It should accurately reflect the real Brightspace dependency that the application consumes.

---

# Final Dependency Graph

The locked-in sequence is:

```text
1. FAKE DATA / BRIGHTSPACE TEST DOUBLE
   Determine the professional, minimal way to emulate
   accurate Brightspace course/activity data.
                    ↓

2. FRONTEND GRAPH
   Port only the thinnest necessary graph-rendering
   functionality from RepoBar.
   Render stub/fake activities under every course.
                    ↓

3. INTERFACE / SCHEMA
   Determine the cleanest representation connecting
   Brightspace activity data to the graph renderer.
   Spend significant design attention here.
                    ↓

4. BACKEND MAPPING
   Convert assignments/quizzes + dates into the graph
   representation defined by the interface.
                    ↓

5. FINAL WIRING + E2E
   Replace seams with real mapped data and verify the
   entire fake-course → visible-graph vertical slice.
```

The dependency graph does **not fan out** for this feature.

Understanding each layer reduces uncertainty for the next one.

The central architectural bottleneck is ultimately the **frontend/backend graph interface**, but we cannot intelligently design that interface until we first understand the RepoBar renderer.

And we cannot reliably develop or visually verify the renderer without accurate fake course data.

Therefore, **fake data is the first dependency**.