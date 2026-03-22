# OpenClaw Splunk O11y Lab

Single-use Kubernetes lab for deploying OpenClaw and instrumenting it with Splunk Observability Cloud.

## What is here

- `scripts/k8s/deploy-lab.sh`: full lab orchestration
- `scripts/k8s/deploy-openclaw.sh`: OpenClaw deploy and secret management
- `scripts/k8s/deploy-splunk-o11y.sh`: Splunk OTel Collector and operator install
- `scripts/k8s/verify-lab.sh`: mutation, gateway, and smoke verification
- `skills/openclaw-splunk-test-lab/SKILL.md`: Codex skill for repeating the workflow

## Quick Start

1. Copy `scripts/k8s/lab.env.example` to `scripts/k8s/lab.env` and fill in the values you need.
2. If the cluster already has Splunk OTel installed, set:
   `SKIP_SPLUNK_OTEL_INSTALL=true`
   `SPLUNK_INSTRUMENTATION_REF=<namespace>/<name>`
3. Deploy:
   `scripts/k8s/deploy-lab.sh --show-token`
4. Verify:
   `scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway`
5. Access OpenClaw:
   `kubectl port-forward svc/openclaw 18789:18789 -n openclaw`

## Live-Test Learnings Baked In

- OpenClaw must use `bind: "lan"` in Kubernetes. `loopback` prevents service reachability.
- Splunk Node auto-instrumentation raises memory pressure. The lab defaults now reserve more heap and pod memory.
- A mutated pod is not proof of working APM. The gateway must listen on `18789` and serve at least one authenticated request.
- If Splunk already exists in the cluster, reuse the existing instrumentation object instead of installing another operator stack.
