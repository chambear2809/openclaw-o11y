# OpenClaw / OpenShell -> O11y Demo Path

This repo now has a concrete two-part demo path:

1. The existing Kubernetes lab deploys a real `openclaw` service and exports real gateway telemetry to Splunk Observability Cloud.
2. `scripts/k8s/demo-scenarios.sh` emits OpenShell-shaped control-plane traces, metrics, and logs so the O11y story can show policy, runtime, and security signals before we replace the synthetic layer with a real NemoClaw/OpenShell runtime.

That split is deliberate. Today this repo deploys OpenClaw on Kubernetes, not OpenShell. The fastest credible demo is therefore:

- real OpenClaw runtime health from the existing lab
- synthetic OpenShell/NemoClaw policy and workflow telemetry over OTLP
- a clean swap point later for real OpenShell hooks and Cisco AI Defense signals

## Source Anchors

- OpenShell README: https://github.com/NVIDIA/OpenShell
  OpenShell is the runtime boundary. It provides sandboxed execution, declarative YAML policies, a gateway auth boundary, policy-enforced egress routing, and hot-reloadable network and inference policy.
- OpenShell policy quickstart: https://github.com/NVIDIA/OpenShell/tree/main/examples/sandbox-policy-quickstart
  The canonical public policy demo is "GitHub GET allowed, POST denied", which is the blocked-action scenario used here.
- NemoClaw README: https://github.com/NVIDIA/NemoClaw
  NemoClaw is the reference stack for running OpenClaw inside OpenShell. It orchestrates the OpenShell gateway, sandbox, inference provider, and network policy, which gives us the control-plane stages to model in telemetry.
- Cisco AI Defense Splunk Integration docs, last updated March 19, 2026: https://securitydocs.cisco.com/docs/ai-def/user/97376.dita
  Confirms Splunk is an official integration surface for AI Defense.
- Cisco AI Runtime Protection docs, last updated March 13, 2026: https://securitydocs.cisco.com/docs/ai-def/user/158910.dita
  Confirms runtime protection is a first-class AI Defense control point.
- Cisco Hybrid Deployment Overview, last updated March 19, 2026: https://securitydocs.cisco.com/docs/ai-def/user/130134.dita
  Confirms the cluster / connector deployment model we should keep in mind for a later in-cluster AI Defense phase.
- Cisco Secure AI Factory with NVIDIA press release, March 16, 2026: https://investor.cisco.com/files/doc_news/Cisco-Secure-AI-Factory-with-NVIDIA-Makes-AI-Easier-to-Deploy-and-Secure-Anywhere-Organizations-Need-It-2026.pdf
  Cisco states AI Defense will support and secure NVIDIA OpenShell runtimes with controls and guardrails for agent actions.

## Concrete Demo Workflow

The demo workflow should stay small and explainable:

1. The agent reads a local config or task file.
2. The agent performs one allowed tool or network action.
3. The agent writes a result.
4. A second branch attempts an action that policy denies.

For the synthetic control-plane layer in this repo, that becomes four scenarios:

- `normal`
  Represents a healthy OpenClaw workflow with one authenticated gateway request and an allowed action path.
- `policy-blocked`
  Represents an OpenShell network deny. The example mirrors the OpenShell quickstart pattern: GitHub `POST` denied by a read-only policy.
- `error-burst`
  Sends repeated requests to an unused local port to create real connection failures while also emitting synthetic runtime-error telemetry.
- `suspicious`
  Represents a multi-step chain that looks like exfiltration or tool misuse: local read, action sequence, blocked outbound `POST`, high suspicion score.

## Telemetry Contract

The demo is easiest to explain if each signal has a fixed owner:

| Signal | Service | Source in this repo | Why it matters |
| --- | --- | --- | --- |
| HTTP latency / error rate / throughput | `openclaw` | Real OpenClaw gateway traffic under Splunk Node.js auto-instrumentation | Runtime health |
| Pod memory / CPU / restarts | Kubernetes infra telemetry | Splunk OTel Collector | Runtime saturation and stability |
| Workflow trace spans | `openshell-demo-control-plane` | `scripts/k8s/demo-emitter.js` | Shows control-plane stages even before full OpenShell is deployed here |
| Policy decision metrics | `openshell-demo-control-plane` | `scripts/k8s/demo-emitter.js` | Powers blocked/allowed dashboards and detectors |
| Security decision logs | `openshell-demo-control-plane` | `scripts/k8s/demo-emitter.js` | Gives searchable event detail and trace correlation |

Synthetic trace spans emitted today:

- `nemoclaw.workflow.run`
- `openshell.policy.evaluate`
- `openclaw.gateway.exercise`
- `security.agent_assessment`

Synthetic metrics emitted today:

- `openshell.demo.scenario_runs`
- `openshell.demo.policy_decisions`
- `openshell.demo.gateway_errors`
- `openshell.demo.action_count`
- `openshell.demo.workflow_latency_ms`
- `openshell.demo.suspicion_score`

Important attributes emitted today:

- `demo.scenario`
- `workflow.outcome`
- `openshell.policy.name`
- `openshell.policy.decision`
- `agent.action.count`
- `security.suspicion_score`
- `gateway.request_total`
- `gateway.error_count`
- `deployment.environment`

## Dashboard Shape

Dashboard 1: Runtime Health

- APM service chart for `service.name=openclaw`
- Error rate and request volume for the last 15 minutes
- Pod restart count, CPU, and memory for the `openclaw` deployment
- `openshell.demo.workflow_latency_ms` split by `demo.scenario`

Dashboard 2: Policy and Security Signals

- `openshell.demo.policy_decisions` split by `openshell.policy.decision`
- `openshell.demo.gateway_errors` split by `demo.scenario`
- `openshell.demo.suspicion_score` as a single-value or time chart
- Log stream filtered to `service.name=openshell-demo-control-plane`
- Trace list filtered to `span.name=openshell.policy.evaluate`

## Detector Shape

Detector 1: OpenClaw Error Burst

- Trigger when `openclaw` error rate rises above the normal baseline or when `openshell.demo.gateway_errors` spikes in the `error-burst` scenario.

Detector 2: Policy Violation Spike

- Trigger when `openshell.demo.policy_decisions` with `openshell.policy.decision=deny` exceeds a small threshold in a short window.

Detector 3: Suspicious Action Rate

- Trigger when `openshell.demo.suspicion_score` stays above a high threshold or when `agent.action.count` is elevated together with a deny decision.

## Commands

Deploy and verify the base lab first:

```bash
scripts/k8s/deploy-lab.sh --show-token
scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway
```

Then exercise the demo path:

```bash
scripts/k8s/demo-scenarios.sh normal
scripts/k8s/demo-scenarios.sh policy-blocked
scripts/k8s/demo-scenarios.sh error-burst
scripts/k8s/demo-scenarios.sh suspicious
```

Or run them end to end:

```bash
scripts/k8s/demo-scenarios.sh all
```

## What Gets Replaced Later

The synthetic layer should be temporary. Once we run NemoClaw/OpenShell directly in-cluster, replace the demo emitter with:

- real OpenShell gateway lifecycle spans
- real policy-engine allow/deny events
- real sandbox status and policy hot-reload metrics
- real AI Defense runtime / threat events when the Cisco connector path is available

The dashboard and detector model above should survive that swap mostly unchanged. The point of this repo stage is to prove the O11y shape now, not wait for every upstream integration to be present.
