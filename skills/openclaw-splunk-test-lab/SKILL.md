---
name: openclaw-splunk-test-lab
description: Use when you need to deploy, verify, troubleshoot, or tear down a single-use Kubernetes lab that runs OpenClaw and instruments it with Splunk Observability Cloud using the Splunk OpenTelemetry Collector and Operator.
---

# OpenClaw Splunk Test Lab

Use this skill when the task is to stand up, verify, troubleshoot, or remove the lab in this directory.

## What this bundle owns

- `scripts/k8s/deploy-openclaw.sh`: deploys OpenClaw, creates or updates the gateway/provider secret, and prints access commands.
- `scripts/k8s/deploy-splunk-o11y.sh`: installs the Splunk OTel Collector Helm chart with the operator enabled for auto-instrumentation.
- `scripts/k8s/deploy-lab.sh`: runs the full lab flow and annotates OpenClaw for Node.js auto-instrumentation.
- `scripts/k8s/verify-lab.sh`: verifies mutation, OTel env, gateway socket health, and optional authenticated smoke traffic.
- `scripts/k8s/lib.sh`: shared helpers for env-file loading, storage-class detection, and instrumentation discovery.
- `scripts/k8s/manifests/`: namespace-scoped OpenClaw manifests.
- `scripts/k8s/lab.env.example`: exact env var names expected by the scripts.

## Workflow

1. Create `scripts/k8s/lab.env` from `scripts/k8s/lab.env.example`, or export the same variables in your shell.
2. Verify the target cluster context before changing anything:
   `kubectl config current-context`
3. Deploy the full lab:
   `scripts/k8s/deploy-lab.sh`
4. If you need the gateway token printed directly:
   `scripts/k8s/deploy-lab.sh --show-token`
5. Verify both layers:
   `kubectl get pods -n openclaw`
   `kubectl get pods -n splunk-o11y`
   `kubectl get instrumentations.opentelemetry.io -n splunk-o11y`
   `scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway`
6. Access the UI:
   `kubectl port-forward svc/openclaw 18789:18789 -n openclaw`
7. Tear the lab down:
   `scripts/k8s/deploy-lab.sh --delete`

## Guardrails

- The OpenClaw side is namespace-scoped and safe to redeploy repeatedly.
- The Splunk operator path is intentionally the official auto-instrumentation route, which means it introduces cluster-scoped CRDs and webhooks in addition to the namespaced release resources.
- Because of that, prefer a dedicated cluster for this lab. `--delete` removes the Helm release and namespaces, but you should still review any remaining cluster-scoped operator artifacts before calling the cluster clean.
- In Kubernetes, keep OpenClaw on `bind: "lan"` so the pod can actually serve on the service port. `loopback` is fine for local-only host installs but breaks the in-cluster service path.
- If the cluster already has a compatible Splunk instrumentation object, set `SKIP_SPLUNK_OTEL_INSTALL=true` or `SPLUNK_INSTRUMENTATION_REF=<namespace>/<name>` and reuse it.
- Node auto-instrumentation increases OpenClaw memory pressure. Keep the higher heap and pod-memory settings unless you have a measured reason to reduce them.
- A mutated pod is not enough. If Splunk does not show the `Openclaw` environment, verify the gateway is actually listening and send at least one authenticated request through it.

## When adjusting the lab

- Change OpenClaw runtime config in `scripts/k8s/manifests/configmap.yaml`.
- Change OpenClaw image via `OPENCLAW_IMAGE`.
- Change Node heap or pod memory via `OPENCLAW_NODE_OPTIONS_BASE`, `OPENCLAW_MEMORY_REQUEST`, and `OPENCLAW_MEMORY_LIMIT`.
- Override the storage class with `OPENCLAW_STORAGE_CLASS` when the cluster has no useful default.
- Override the exported environment tag with `OPENCLAW_DEPLOYMENT_ENVIRONMENT`.
- Change Splunk collector/operator settings by editing `scripts/k8s/deploy-splunk-o11y.sh`.
- If OpenClaw is moved to a different namespace or the Splunk release name changes, keep the deployment annotation in `scripts/k8s/deploy-lab.sh` aligned.

## Troubleshooting shortcuts

- If the pod is `Running` but the UI still shows no OpenClaw environment, run `scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway`.
- If the gateway never opens port `18789`, check `kubectl logs deployment/openclaw -n openclaw` for Node OOMs or startup errors.
- If the cluster already has Splunk in another namespace, prefer reusing that instrumentation instead of installing a second operator stack.
