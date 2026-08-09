# RepoBar Vision

RepoBar is a fast native maintainer cockpit. It should make repository pressure, CI, releases, and local checkout state legible without becoming a browser replacement.

## GitHub-specific product

RepoBar is built specifically for GitHub.com and GitHub Enterprise. It is not a general multi-provider repository client.

- Product behavior may rely on GitHub's repository, issue, pull request, Actions, release, authentication, and API semantics.
- Do not add provider selection, credentials, API clients, compatibility layers, or conditional UI for other repository hosts to RepoBar core.
- Shared Git and HTTP utilities are welcome when they directly improve the GitHub experience, not as extension points for additional providers.
- Support for GitLab or other repository hosts belongs in a maintained fork or a separate tool.
