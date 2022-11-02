# git-structure-mirror

Mirrors the structure of a git repo without mirroring any other information
except commit SHA and ref names.

Specifically, commit and tag messages, worktree files, etc are not mirrored.
- Commit messages in the mirrored repo contain only the SHA of the original
  commit in the source repo.
- Source repo commits have a note added that contains the SHA of the mirrored
  commit.

I use this mainly to run CI/CD.
You might want to do this if you cannot keep the original repo in CI/CD for
whatever eason:
- The source repo is HUGE and checking out a new copy for CI/CD is not
  feasible. In that case, a custom solution to provide the source worktree
  (btrfs CoW snapshot mounts, overlayfs, etc) can be used as the CI/CD step.
- You want to use a public CI/CD orchestrator without leaking secrets from a
  private repo to it. In this case, you can control the runners and provide a
  custom way for the runners to access the source repo without the orchestrator
  knowing.
