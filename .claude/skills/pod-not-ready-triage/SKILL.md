---
name: pod-not-ready-triage
description: >-
  Triage a workload in this cluster that is missing, Pending, CrashLoopBackOff,
  ImagePullBackOff, Running but not Ready, or Ready but unreachable from
  another pod (mostly crypto-wallet-app: frontend, order-service,
  wallet-service, postgres-db; also kafka-exporter). Use when someone says a
  Deployment "doesn't show up", pods are stuck, restarting, not Ready, "Too
  many pods", or a pod "cannot reach" a Service / gets connection timeouts
  while the target looks healthy. Walks the platform-specific check order:
  events, Kyverno admission, ExternalSecret sync, NetworkPolicy default-deny,
  17-pods-per-node ceiling, ECR image pull.
---

# Pod not ready: triage runbook

Use this when a workload doesn't run, or runs without becoming Ready. Diagnose
read-only, name the root cause with evidence, and propose a fix that goes
through git. Don't change the live cluster. ArgoCD `selfHeal` reverts edits
to the objects it manages. An object created by hand isn't tracked, so ArgoCD
leaves it alone, but it isn't in git either: it gets lost on the next rebuild
and is invisible to review.

## Tools, in order of preference

1. **Radar MCP** (`mcp__radar__*`), if `make radar` is running. It is
   read-only by design (`ai-readonly` ServiceAccount, no `secrets`, no `exec`).
   Start with `issues` (namespace-scoped), then `diagnose` on the suspect
   workload. It bundles logs, Warning events and startup blockers.
2. **kubectl** with the operator's context, **read verbs only**: `get`,
   `describe`, `logs`, `get events`. Never `get secret -o yaml`, never `exec`
   into app pods to read env.

## Check order

Stop at the first check that explains the symptom **and** accounts for every
observation. Record what each check ruled out.

### 1. Does the object exist at all? (Kyverno admission)

Both ClusterPolicies run in **Enforce** mode
(`k8s/apps/kyverno-policies/`). A rejected Deployment is never written to
etcd. You won't find it, its ReplicaSet or its pods. The only trace is a
`PolicyViolation` event:

```bash
kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail
kubectl get clusterpolicy        # both should be Ready
```

Radar: `get_events` for the name, then `get_resource` on the ClusterPolicy.

- `require-resource-limits` (rule `autogen-check-resource-limits` for
  Deployments): every container needs `resources.limits.cpu` and `.memory`.
- `require-pod-security`: `runAsNonRoot: true`, `allowPrivilegeEscalation:
  false`, `capabilities.drop: ["ALL"]`, no privileged/hostPID/hostIPC/hostNetwork.
  Init containers count too.
- Excluded namespaces: `kube-system`, `argocd`, `kyverno`, `monitoring`. Pods
  anywhere else are checked.
- If the Deployment exists but the ReplicaSet has no pods, run
  `kubectl describe rs`. Kyverno also blocks at the Pod level
  (`FailedCreate ... blocked due to the following policies`).

**Fix:** copy the securityContext and resources from
`k8s/components/wallet-service.yaml`. Never exempt a namespace or switch the
policy to Audit.

### 2. Pending: scheduling and the 17-pods-per-node ceiling

The cluster is 3× `t3.medium`. The VPC CNI caps each node at **17 pods**.
Look for `FailedScheduling` with `Too many pods`, or `Insufficient cpu/memory`:

```bash
kubectl describe pod <pod> -n <ns> | sed -n '/Events/,$p'
kubectl get pods -A -o wide --field-selector status.phase=Running | awk '{print $8}' | sort | uniq -c
kubectl get hpa -n crypto-wallet-app      # several HPAs near maxReplicas at once?
```

Also check for a PVC stuck `Pending` (Postgres and Kafka use StorageClass `gp3`,
EBS CSI) or a volume attach that can't move across AZs.

**Report capacity limits to the user. Don't work around them quietly** (no
lowering other apps' limits, no deleting pods to make room).

### 3. CreateContainerConfigError: a missing Secret (ESO)

`wallet-service` and `postgres-db` read `crypto-db-secret`. ESO creates it from
Vault (`k8s/components/external-secret.yaml`). If the Secret doesn't exist the
pod shows `CreateContainerConfigError: secret "crypto-db-secret" not found`.

```bash
kubectl get externalsecret -n crypto-wallet-app    # SecretSynced must be True
kubectl get clustersecretstore                      # vault-crypto-app must be Ready
```

If either is not Ready, switch to the **vault-eso-secrets** skill.

### 4. ImagePullBackOff / ErrImagePull (ECR)

App images are `079000477935.dkr.ecr.us-east-1.amazonaws.com/<svc>:<commit-sha>`
with `imagePullPolicy: Always`. The nodes pull with their IAM node role. No
imagePullSecret is involved.

- `manifest unknown` / `not found`: the tag isn't in ECR. `ci.yml` owns these
  tags (`chore/pin-images-<sha>` PRs). Check the build-and-push run for that
  SHA. Don't hand-edit the tag.
- `401/403`: node role or ECR repo policy (Terraform, `terraform/infra`).
- Third-party images (`postgres:15`, `danielqsj/kafka-exporter`,
  `bitnamilegacy/kafka`, `busybox`): Docker Hub rate limits, or a removed
  tag (Bitnami moved to `bitnamilegacy/*`).

### 5. CrashLoopBackOff: read the previous container's logs

```bash
kubectl logs <pod> -n <ns> --previous --tail=100
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState}'
```

- `OOMKilled`: limit too low for the workload. Size it in the manifest (via PR)
  from real usage (`kubectl top pod`, Radar `top_resources`).
- `readOnlyRootFilesystem` errors (`EROFS`, `read-only file system`): the process
  writes somewhere other than its `emptyDir` mounts. Add a mount for that path.
- `EACCES` on startup: the image's `USER` doesn't match `runAsUser`, or `fsGroup`
  is missing on a volume.
- kafka-exporter: its `wait-for-kafka` init container holds it in `Init` while
  the broker is down. That's expected, not a crash.

### 6. Running but not Ready: probes and dependencies

- The probes: `wallet-service`/`order-service` `GET /health` on 3000, frontend on
  8080. Timeouts under CPU contention show up as `Readiness probe failed:
  context deadline exceeded`.
- `wallet-service` `/health` doesn't check the DB. `GET /` does, so the pod can be
  Ready while Postgres is down. Postgres has **no readinessProbe** at all.

### 7. Ready but unreachable: NetworkPolicy default-deny

`crypto-wallet-app` denies all ingress by default
(`k8s/components/network-policies.yaml`). The allowed hops:

```
ingress-nginx --8080--> frontend --3000--> wallet-service --5432--> postgres
                                 \--3000--> order-service
k6-load-generator --8080--> frontend
```

A caller missing from this list times out (no RST). Radar: `diagnose` with
`kind: service, probe: true`, then `get_resource` on the policies. **Fix:**
add one allow rule (source selector + port) to `network-policies.yaml` through
a PR. Select only the target that's actually called: don't append the new
source to `allow-frontend-to-backends`, because it selects **both** backends and
would also open order-service. Never an allow-all or a namespace-wide rule.

## Finish

Report three things: the root cause with the evidence (event, log line or
condition), what you ruled out, and the fix as a git change (file + diff),
following CLAUDE.md's branch/PR flow. If a fix needs a live action (rollout
restart, scaling, deleting a pod), say exactly which command and **ask
before running it**.
