---
paths:
  - "**/*.rs"
---

# Test vs. deliberate-feature conflict

Before changing behavior to make a failing test pass after a rebase, check `git log`/`git blame` on the touched code path for a recent deliberate commit. If the test's assumption conflicts with intentional behavior, update the test and say so — never silently revert the feature to turn tests green.
