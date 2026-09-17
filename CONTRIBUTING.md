# Contributing

## Branch & PR workflow

`main` is protected by convention: **no direct pushes.** Every change —
manifests, Terraform, services, docs — lands through a feature branch and a
Pull Request.

1. Branch off `main`: `feat/<task-name>` for new capability, `fix/<task-name>`
   for a bug/regression (e.g. `feat/plat-406-hpa-tuning`).
2. Commit your changes on that branch, push it to `origin`, and open a PR
   against `main` with `gh pr create` — summarize what changed and how you
   validated it (test output, `kubectl` checks, etc.) in the PR body.
3. [PR Checks](.github/workflows/pr-checks.yml) runs automatically on open/
   update: YAML lint (files the PR touches), `kustomize build` across every
   `kustomization.yaml`, a client-side `kubectl apply --dry-run` of every
   rendered manifest, and `helm template` of every ArgoCD Application's
   chart + committed values. All must pass before merging.
4. `main`'s only writer besides a merged PR is
   [ci.yml](.github/workflows/ci.yml)'s `update-manifests` job, which pins
   Deployment image tags after a build — that's an automated, narrowly
   scoped exception, not a precedent for pushing other changes directly.

## Validating against the live cluster before merging

Some changes (resource sizing, autoscaling, anything you want to watch
under real load) are worth confirming against the live cluster before a PR
merges, on top of what PR Checks already does statically. ArgoCD's
`selfHeal` will otherwise revert any live edit that isn't yet the
committed state on `main`, so:

1. Do the work on your feature branch and commit it there first — a live
   check should always be validating something already committed, not
   uncommitted edits that could get lost.
2. Temporarily pause `selfHeal` on the target Application:
   ```
   kubectl patch application <app> -n argocd \
     --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```
3. `kubectl apply` the rendered manifests from your branch and validate
   (load test, `kubectl get hpa`, probe/restart behavior, etc.).
4. Restore `selfHeal`:
   ```
   kubectl patch application <app> -n argocd \
     --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```
   Once the PR merges, ArgoCD picks up the same committed manifests on its
   own and reconciles cleanly — nothing further to do.
