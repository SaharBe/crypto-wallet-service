# AI-assisted operations: demo and guardrail evidence (PLAT-504)

Recorded on 2026-10-25 against the live EKS cluster, Radar v1.18.1, Claude
Code 2.1.121. Setup and design: [README → AI-Assisted Operations](../README.md#ai-assisted-operations).

## How the demo was run

Each failure was injected on throwaway resources only (no real workload was
touched), then removed. Claude Code ran headless, restricted to Radar's MCP
tools. Bash, file reads/edits and web access were disallowed, so every fact
in the diagnosis came from the cluster through Radar:

```bash
claude -p "<question>" --strict-mcp-config --mcp-config .mcp.json \
  --allowedTools mcp__radar \
  --disallowedTools "Bash Edit Write Read Glob Grep WebFetch WebSearch Task Agent NotebookEdit"
```

The questions describe the symptom only, the way an on-call engineer would
ask them. Neither question names Kyverno or NetworkPolicy.

## Scenario 1: a Deployment rejected by Kyverno

**Injected:** `kubectl apply` of a `demo-no-limits` Deployment with no
`resources.limits`. Kyverno's `require-resource-limits` (Enforce) blocked it
at admission, so the object never existed. The only trace was a
`PolicyViolation` event on the ClusterPolicy.

**Asked:** "I applied a Deployment called demo-no-limits to the
crypto-wallet-app namespace a minute ago but it doesn't show up anywhere.
What happened, and how do I fix it?"

**Result:** correct root cause (admission rejection by
`require-resource-limits`, rule `autogen-check-resource-limits`) and the
right fix (set CPU/memory limits).

Radar tool calls, in order:

1. `issues` `{"namespace": "crypto-wallet-app"}`
1. `get_events` `{"namespace": "crypto-wallet-app", "name": "demo-no-limits", "limit": 20}`
1. `get_resource` `{"kind": "Deployment", "name": "demo-no-limits", "namespace": "crypto-wallet-app"}`
1. `get_resource` `{"kind": "ClusterPolicy", "name": "require-resource-limits"}`

7 turns, 41 s. No tool call outside Radar; no permission denials.

<details>
<summary>Claude's answer (verbatim)</summary>

Diagnosis confirmed. Here's exactly what happened and how to fix it.

---

#### What happened

**Kyverno's `require-resource-limits` ClusterPolicy (`validationFailureAction: Enforce`) rejected the Deployment at the API server admission layer.**

When you ran `kubectl apply`, Kyverno's validating webhook (`validate.kyverno.svc-fail`) intercepted the request before it was written to etcd. Because the pod template had no `resources.limits.cpu` / `resources.limits.memory`, the rule `autogen-check-resource-limits` (auto-generated from the base Pod rule to also cover Deployments) returned a deny. The error kubectl printed would have been something like:

```
Error from server: admission webhook "validate.kyverno.svc" denied the request:
resource Deployment/crypto-wallet-app/demo-no-limits was blocked due to the following policies
require-resource-limits:
  autogen-check-resource-limits: CPU and memory limits are required for all containers.
```

Because the object never reached etcd, there is no Deployment, no ReplicaSet, no Pod, and no namespace events — it is as if the `apply` never happened. This is correct Enforce-mode behavior, not a bug.

**Why `crypto-wallet-app` specifically:** the policy excludes only `kube-system`, `argocd`, `kyverno`, and `monitoring` — your namespace is fully covered.

---

#### How to fix it

Add `resources.requests` **and** `resources.limits` (both `cpu` and `memory`) to every container in the Deployment's pod template:

```yaml
spec:
  template:
    spec:
      containers:
        - name: your-container
          image: your-image
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
```

Size the values appropriately for the workload, then re-apply. The webhook will pass and the Deployment will be created.

> **Note:** `requests` aren't strictly required by the Kyverno rule (it only checks `limits`), but you should set them too — requests are what the scheduler uses for placement, and omitting them means `requests == limits` implicitly under some configurations, which can cause over-scheduling on the `t3.medium` nodes (17-pod-per-node ceiling).

</details>

Reviewer notes: the quoted kubectl error is a reconstruction; the agent
says so ("something like"), and the real webhook name was
`validate.kyverno.svc-fail`. The closing note on `requests` is imprecise:
when `requests` are omitted, Kubernetes defaults them to the `limits`
values.

## Scenario 2: traffic blocked by NetworkPolicy

**Injected:** a `demo-netpol-client` Pod (with limits) curling
`wallet-service:3000/health` every 5 s. Default-deny ingress drops it,
because only `app: frontend` may reach the backends.

**Asked:** "The pod demo-netpol-client in crypto-wallet-app keeps logging
that it cannot reach wallet-service:3000, but wallet-service itself looks
healthy. Find the root cause and tell me how to fix it."

**Result:** correct root cause (`default-deny-ingress` +
`allow-frontend-to-backends` admits only `app: frontend`), and the fix it
proposed follows the repo rules: one-hop allow rule, committed in
`k8s/components/network-policies.yaml` through a PR, not a live
`kubectl apply`.

Radar tool calls, in order:

1. `issues` `{"namespace": "crypto-wallet-app", "filter": "category_group == \"networking\""}`
1. `diagnose` `{"kind": "pod", "namespace": "crypto-wallet-app", "name": "demo-netpol-client", "since": "30m"}`
1. `diagnose` `{"kind": "service", "namespace": "crypto-wallet-app", "name": "wallet-service", "probe": true}`
1. `get_resource` `{"kind": "networkpolicy", "name": "allow-frontend-to-backends", "namespace": "crypto-wallet-app"}`
1. `get_resource` `{"kind": "networkpolicy", "name": "default-deny-ingress", "namespace": "crypto-wallet-app"}`

7 turns, 40 s. No tool call outside Radar; no permission denials.

<details>
<summary>Claude's answer (verbatim)</summary>

Root cause confirmed. Here's the full picture:

---

#### Root Cause: NetworkPolicy blocks `demo-netpol-client` → `wallet-service:3000`

The `crypto-wallet-app` namespace has a **default-deny-all-ingress** policy (`podSelector: {}`, no ingress rules) that blocks every pod-to-pod ingress connection unless an explicit allow rule exists.

The only allow rule for port 3000 is `allow-frontend-to-backends`, which permits ingress to `wallet-service`/`order-service` **only from pods with label `app=frontend`**:

```yaml
# allow-frontend-to-backends
spec:
  podSelector:
    matchExpressions:
      - key: app
        operator: In
        values: [wallet-service, order-service]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend   # ← only this source is allowed
      ports:
        - port: 3000
```

`demo-netpol-client` has labels `app=demo-netpol-client, plat504-demo=true` — it does **not** match `app=frontend`, so every SYN packet it sends to `wallet-service:3000` is silently dropped by the VPC CNI enforcer. That's why it times out at the TCP level (`-m 3` curl flag), not an HTTP error.

---

#### How to fix

Add a new, targeted NetworkPolicy in `k8s/components/network-policies.yaml` (do **not** kubectl-apply directly — ArgoCD will revert it):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-demo-client-to-wallet
  namespace: crypto-wallet-app
spec:
  podSelector:
    matchLabels:
      app: wallet-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: demo-netpol-client
      ports:
        - port: 3000
          protocol: TCP
```

This follows the CLAUDE.md rule: one hop at a time, source selector + port, no allow-all.

**Deployment path:**
1. Edit `k8s/components/network-policies.yaml` to add the policy above.
2. Ensure it's listed in `k8s/components/kustomization.yaml` (it already should be if network-policies.yaml is the single file for the namespace).
3. Run local validation: `yamllint`, `kubectl kustomize`, `kubeconform`.
4. Push on a `feat/...` branch and open a PR — ArgoCD will sync it to the cluster on merge.

If you want the fix applied immediately (not wait for a merge), you can use the live-cluster validation procedure from CLAUDE.md: pause `selfHeal` on `crypto-wallet-app`, `kubectl apply -k k8s/components`, verify the pod starts logging `OK wallet-service`, then restore `selfHeal` — but the change still needs to land in git.

</details>

The `diagnose` call with `probe: true` tried to test the route through the
API server proxy. RBAC refused it ("Your identity lacks get services/proxy
or get pods/proxy"), and the agent carried on from the policy objects. No
probe Pod was created.

## Guardrail verification

All checks run with the `ai-readonly` identity (`~/.kube/ai-readonly.kubeconfig`),
the same one Radar uses.

| Attempt | Path | Result |
|---|---|---|
| `get pods -A`, Applications, ClusterPolicies, ExternalSecrets, NetworkPolicies, Pod logs | kubectl | allowed |
| `get secrets -A`, `get secret argocd-initial-admin-secret` | kubectl | `forbidden` |
| `delete pod`, `scale deploy`, `patch application` (server dry-run) | kubectl | `forbidden` |
| `exec`, `port-forward` | kubectl | `forbidden` |
| `create token` for its own ServiceAccount | kubectl | `forbidden` |
| Restart `frontend` | Radar REST API (`POST /api/workloads/.../restart`, what the UI calls) | HTTP 403, `cannot patch resource "deployments"`; Deployment generation unchanged |
| Full MCP endpoint `/mcp` | MCP | HTTP 404 |
| `tools/list` on `/mcp-readonly` | MCP | 27 tools, all `readOnlyHint: true` |
| `tools/call manage_workload` (a write tool) | MCP | `unknown tool` |
| `diagnose` with `probe: true` | MCP | denied by RBAC (no `services/proxy`) |
| Contexts visible to Radar | Radar | 1 (`crypto-wallet-ai-readonly`), so it can't switch to the operator's admin context |

The REST row is the important one: Radar's `--mcp-read-only` only filters
MCP tools and doesn't cover its UI or REST API. The API server enforces the
read-only ClusterRole whichever path a request takes.
