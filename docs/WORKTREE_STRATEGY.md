# Git Worktree Merging and Coordination Strategy

## Overview

Multiple agents work in parallel on isolated git worktrees inside containers. This document describes how to coordinate merges back into main repository.

## Worktree Lifecycle

### Phase 5: Builder Agents (Parallel Execution)

```
Time  Builder-1                Builder-2                Builder-3
 t0   Create worktree-1        Create worktree-2        Create worktree-3
      Add feature-1 branch     Add feature-2 branch     Add feature-3 branch
 
 t1   Edit files in ws-1       Edit files in ws-2       Edit files in ws-3
      (own namespace)          (own namespace)          (own namespace)
 
 t2   Implement Phase 5        Implement Phase 5        Implement Phase 5
      (2-4 hours work)         (2-4 hours work)         (2-4 hours work)
 
 t3   COMPLETE               COMPLETE                COMPLETE
      Commit changes         Commit changes          Commit changes
      (worker-1 branch)      (worker-2 branch)       (worker-3 branch)
```

### Merge Strategy: Integration-Branch Pattern

```
After all builders complete (t3):

MERGE PHASE (Sequential, atomic):

Step 1: Builder-1 merges
  git merge --squash worker-1 --into integration
  git commit -m "Merge Builder-1: feature-1"
  (5 seconds, guaranteed no conflicts due to disjoint ownership)

Step 2: Builder-2 merges
  git rebase integration worker-2
  git merge --squash worker-2 --into integration
  git commit -m "Merge Builder-2: feature-2"
  (5 seconds, guaranteed no conflicts)

Step 3: Builder-3 merges
  git rebase integration worker-3
  git merge --squash worker-3 --into integration
  git commit -m "Merge Builder-3: feature-3"
  (5 seconds, guaranteed no conflicts)

RESULT: All work merged to 'integration' branch (clean, linear history)
```

### Phase 6: Gatekeeper Validation

```
Gatekeeper receives: integration branch (all Phase 5 work merged)

Phase 6 Tasks:
1. Validate all merged code (tests, linting, etc.)
2. If PASS: Merge integration → main (atomic commit)
   git merge integration -m "Phase 5 complete: features 1-3"
3. If FAIL: Identify failing builder, escalate for fix
   git log integration | identify commits by builder
   Rollback if needed: git reset --hard <pre-merge-hash>
```

## Merge Guarantees (Why This Works)

### Disjoint File Ownership

Mutl3y foreman assigns **non-overlapping file ownership** to each builder:

```
Builder-1: owns files src/feature-1/*, src/config-1.js
Builder-2: owns files src/feature-2/*, src/config-2.js
Builder-3: owns files src/feature-3/*, src/config-3.js
```

**Textual merge conflicts = 0** (different builders edit different files)

### Why Sequential Merges Guarantee Safety

1. **Builder-1 merges first**: All its files go into integration (no conflicts possible)
2. **Builder-2 rebases on updated integration**: Its changes apply cleanly (different files)
3. **Builder-3 rebases on updated integration**: Its changes apply cleanly (different files)

Result: **3 builders, 0 conflicts, guaranteed success**

## Semantic Conflicts (Not Prevented by File Ownership)

File disjointness prevents **textual** conflicts but NOT **semantic** ones:

### Example Semantic Conflict
```
Builder-1: Adds new function foo() to lib.js
Builder-2: Calls foo() in a different file (doesn't know about it)
Builder-3: Exports foo() but Builder-2's call fails at runtime

Phase 5 Merge: Succeeds (different files)
Phase 6 Gatekeeper: FAILS (tests catch the issue)
Recovery: Fix and re-merge in next cycle
```

**Solution**: Phase 6 gatekeeper runs full test suite. If semantic issue found:
1. Identify problematic builder
2. Escalate for fix
3. Re-test
4. Merge only after passing

## Worktree Storage and Cleanup

### Storage Per Builder

```
Builder  Worktree Size    Reason
------   -------         -------
 1       ~100-150 MB     Feature files + .git metadata
 2       ~100-150 MB     Feature files + .git metadata
 3       ~100-150 MB     Feature files + .git metadata
------   -------
TOTAL    ~300-450 MB     3 builders working in parallel
```

### Cleanup After Phase 5 Completes

```bash
# After successful merge to 'integration':
git worktree remove feature-1
git worktree remove feature-2
git worktree remove feature-3
# Reclaims 300-450 MB
```

### Cleanup After Phase 6 (Gatekeeper) Validates

```bash
# After gatekeeper confirms integration → main succeeded:
git branch -d integration    # Remove integration branch
# Clean up temporary branch used during Phase 5/6
```

## Handling Merge Failures

### Scenario 1: Builder-2's Rebase Fails
```
Error: Builder-2's changes don't apply cleanly to updated integration

Action:
1. Rebase Builder-2 manually
2. Resolve conflicts (shouldn't happen if ownership enforced)
3. Re-attempt merge
4. If still fails: Escalate to Builder-2 for investigation
```

### Scenario 2: Gatekeeper Tests Fail After Merge

```
Error: integration branch tests fail

Action:
1. Identify failing builder (check commit log)
2. Revert that builder's commit:
   git reset --hard <pre-commit-hash>
3. Notify builder of failure
4. Builder fixes issue locally, re-merges
5. Re-run gatekeeper validation
```

### Scenario 3: Critical Issue Detected During Phase 6

```
Error: Security vulnerability in merged code

Action:
1. git reset --hard <pre-merge-hash>  # Undo all Phase 5 merges
2. Escalate to security team
3. Builders fix locally, re-merge with security review
4. Re-run Phase 6 with extra scrutiny
```

## Config File Merge Considerations

### Potential Conflicts: package.json, pyproject.toml

If multiple builders update shared files:

```
Builder-1: Updates package.json (adds @babel/core)
Builder-2: Updates package.json (adds lodash)
Builder-3: Updates package.json (updates react version)

Merge: CONFLICT (all editing same file)
```

### Prevention Strategy

**Option 1: Assign config file ownership**
- Builder-1 owns package.json updates
- Others request changes through Builder-1

**Option 2: Deep merge during gatekeeper**
- Allow overlapping edits
- Run deep merge tool during Phase 6
- Validate result with full integration tests

**Option 3: Separate config repos**
- Move config to separate submodule
- Managed independently of feature work

Recommended: **Option 1** (single owner for each config file)

## Implementation Checklist

```
□ Assign file ownership to each builder (document in /docs/OWNERSHIP.md)
□ Create integration branch template (git branch integration main)
□ Configure gatekeeper validation script (full test suite)
□ Document merge failure procedures
□ Test merge strategy on small codebase first
□ Monitor for semantic conflicts (add telemetry)
□ Automate cleanup after successful Phase 6
```

## Example Workflow (Real Scenario)

### Time 0: Start Phase 5

```bash
# Phase 5 starts (Orchestrator)
git branch integration main  # Create integration branch

# Builder-1 container
git worktree add --detach feature-1
cd feature-1
# Implement feature, commit changes

# Builder-2 container (parallel)
git worktree add --detach feature-2
cd feature-2
# Implement feature, commit changes

# Builder-3 container (parallel)
git worktree add --detach feature-3
cd feature-3
# Implement feature, commit changes
```

### Time T1: All Builders Complete

```bash
# Orchestrator: Phase 5 → Phase 6 transition
git checkout integration

# Merge Builder-1
git merge --squash feature-1
git commit -m "Merge Builder-1: feature-1 (3 files, 50 LOC)"
# Result: feature-1 on integration

# Rebase + merge Builder-2
git worktree prune
git worktree add --detach feature-2-rebase feature-2
git -C feature-2-rebase rebase integration
git merge --squash feature-2-rebase
git commit -m "Merge Builder-2: feature-2 (2 files, 30 LOC)"
# Result: feature-1 + feature-2 on integration

# Rebase + merge Builder-3
git worktree add --detach feature-3-rebase feature-3
git -C feature-3-rebase rebase integration
git merge --squash feature-3-rebase
git commit -m "Merge Builder-3: feature-3 (4 files, 75 LOC)"
# Result: feature-1 + feature-2 + feature-3 on integration

# Cleanup
git worktree remove feature-1
git worktree remove feature-2
git worktree remove feature-3
git worktree remove feature-2-rebase
git worktree remove feature-3-rebase
```

### Time T2: Gatekeeper Validates

```bash
# Phase 6: Gatekeeper validates integration branch
npm test      # Run full test suite
npm run lint  # Run linter
npm run build # Build project

# If all pass:
git checkout main
git merge integration -m "Phase 5 complete: 3 features"
git branch -d integration  # Cleanup temporary branch

# If any fail:
git log --oneline integration | head -10  # Identify builder
git revert <commit-hash>                  # Revert failing builder
# Notify builder, request fix, re-test
```

## Monitoring and Alerts

```
Metric                          Alert Threshold
======                          ================
Merge conflicts                 > 0 (should be 0)
Gatekeeper test failures        > 0 (should be 0)
Semantic conflicts detected     > 0 (should be 0)
Builder rebase time            > 30 seconds (investigate)
Total Phase 5→6 time           > 5 minutes (investigate)
Worktree cleanup time          > 10 seconds (investigate)
```

## Summary

**Strategy: Integration-branch with sequential merges**
- ✅ Guarantees zero textual conflicts (file disjointness)
- ✅ Catches semantic conflicts at Phase 6 (tests)
- ✅ Clear failure handling (revert + escalate)
- ✅ Automatic cleanup (reclaims storage)
- ✅ Audit trail (each merge is a named commit)
- ✅ Easy to scale (works with N builders)

For more context, see [ARCHITECTURE.md](ARCHITECTURE.md) and [GUIDE.md](GUIDE.md).
