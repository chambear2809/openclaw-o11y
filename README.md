# OpenClaw Splunk O11y Lab

This repository builds a single-use Kubernetes lab for running OpenClaw with Splunk Observability Cloud instrumentation. The goal is not just to start a pod with OpenTelemetry environment variables, but to produce a repeatable deployment that can be verified end to end:

- OpenClaw starts successfully inside Kubernetes.
- The OpenTelemetry operator injects Splunk Node.js auto-instrumentation.
- The running container exports spans to the Splunk OpenTelemetry Collector.
- The exported spans carry `service.name=openclaw` and `deployment.environment=Openclaw`.
- The gateway serves real HTTP traffic so the `Openclaw` environment becomes visible in Splunk APM.

The workflow in this repo was adjusted from a live cluster run. The biggest lesson from that run was that "mutated pod" was not enough. The app also had to bind on the Kubernetes service interface, stay within memory limits under auto-instrumentation, and successfully serve at least one authenticated request.

## What This Repo Contains

- `scripts/k8s/deploy-lab.sh`
  Orchestrates the full lab flow: Splunk OTel install or reuse, OpenClaw deploy, and auto-instrumentation annotation.
- `scripts/k8s/deploy-openclaw.sh`
  Creates or updates the OpenClaw secrets, applies the namespace-scoped manifests, sets OpenTelemetry environment variables, and restarts the deployment.
- `scripts/k8s/deploy-splunk-o11y.sh`
  Installs the Splunk OpenTelemetry Collector Helm chart with the operator and CRDs enabled.
- `scripts/k8s/verify-lab.sh`
  Verifies the live pod was mutated, has the expected OTEL environment variables, is listening on the gateway port, and can serve an authenticated smoke request.
- `scripts/k8s/demo-scenarios.sh`
  Exercises the demo path and emits OpenShell-shaped traces, metrics, and logs into Splunk through the collector.
- `scripts/k8s/demo-emitter.js`
  The OTLP emitter used by `demo-scenarios.sh` to publish synthetic control-plane telemetry.
- `scripts/k8s/lib.sh`
  Shared shell helpers for loading `lab.env`, resolving storage classes, and discovering an existing instrumentation object.
- `scripts/local/bootstrap-nemoclaw.sh`
  Runs the stock local NemoClaw/OpenShell bootstrap, configures the OpenShell gateway to use OpenAI through a host relay, and restarts OpenClaw under OTEL instrumentation.
- `scripts/local/ensure-collector.sh`
  Reuses a local Docker OTEL collector on `4318` when one exists, or starts a repo-owned collector container if none is found.
- `scripts/local/ensure-gateway-otlp-forwarder.sh`
  Deploys an in-gateway OTLP forwarder service inside the OpenShell k3s cluster so the sandbox can export telemetry to a reachable cluster service instead of a host port.
- `scripts/local/ensure-openai-relay.sh`
  Starts or reuses a host-local OpenAI relay so the OpenShell gateway can call OpenAI through `host.docker.internal` even when direct egress to `api.openai.com` is blocked.
- `scripts/local/openai-relay.js`
  The lightweight OpenAI-compatible relay used by the local NemoClaw/OpenShell flow.
- `scripts/local/verify-nemoclaw-otel.sh`
  Verifies the repeatable local path end to end: collector, relay, forwarder, gateway env, proxy-routed OTLP reachability, and optional agent smoke.
- `scripts/local/presets/otel-collector.yaml`
  Policy preset that allows the sandbox to export OTLP traces to the in-gateway OTLP forwarder service.
- `scripts/local/lab.env.example`
  Example environment file for the local NemoClaw/OpenShell flow.
- `scripts/k8s/manifests/`
  The OpenClaw ConfigMap, Deployment, Service, PVC, and kustomization used by the lab.
- `docs/openshell-demo-path.md`
  The source-backed OpenClaw/OpenShell/NemoClaw -> O11y architecture and demo plan for this repo.
- `skills/openclaw-splunk-test-lab/SKILL.md`
  Codex skill instructions for repeating the deployment and troubleshooting flow.

## Architecture

At a high level, the lab does the following:

1. Installs or reuses a Splunk OpenTelemetry Collector and OpenTelemetry Operator in the cluster.
2. Deploys OpenClaw into the `openclaw` namespace.
3. Annotates the OpenClaw deployment with `instrumentation.opentelemetry.io/inject-nodejs`.
4. Lets the operator inject the Splunk Node.js auto-instrumentation bundle into the pod.
5. Exports OpenClaw traces to the node-local Splunk OTel agent at `splunk-otel-collector-agent.<namespace>.svc:4317`.
6. Tags telemetry with `OTEL_SERVICE_NAME=openclaw` and `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=Openclaw`.

The repository currently uses the official Splunk operator-based auto-instrumentation path. That matters because the Splunk side is not purely namespace-scoped. Installing the operator introduces cluster-scoped CRDs and webhooks. This is fine for a dedicated test cluster, but you should be deliberate about it.

## Live-Test Learnings Baked Into The Manifests

The current manifests already include the fixes discovered during the live EKS test:

- OpenClaw uses `bind: "lan"` in Kubernetes.
  `loopback` works for host-local setups but prevents service reachability inside the cluster.
- The pod reserves more memory and Node heap headroom.
  Splunk Node.js auto-instrumentation increased memory pressure enough to push the earlier pod into OOM and prevent stable startup.
- The deployment has TCP startup, readiness, and liveness probes on port `18789`.
  This prevents the deployment from reporting healthy before the gateway is actually accepting connections.
- The verification flow includes an authenticated smoke request.
  This matters because an injected pod that never serves traffic will not produce the normal APM service behavior you expect in Splunk.

## Prerequisites

You need the following on the machine running the scripts:

- `kubectl`
- `helm`
- `zsh`
- Access to the target Kubernetes cluster
- An OpenClaw provider API key
  `OPENAI_API_KEY` is the default path in the provided template, but the deploy script also supports `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, and `OPENROUTER_API_KEY`.

You also need one of these Splunk setups:

- A Splunk Observability Cloud realm and access token so this repo can install its own collector and operator
- An existing compatible instrumentation object already present in the cluster

## Configuration

Start by copying the example environment file:

```bash
cp scripts/k8s/lab.env.example scripts/k8s/lab.env
```

`scripts/k8s/lab.env` is ignored by git and is the intended place for cluster-specific values and secrets.

### Required OpenClaw Input

At least one provider key must be present:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `GEMINI_API_KEY`
- `OPENROUTER_API_KEY`

### Required Splunk Input

If this repo is installing Splunk OTel for you, set:

- `SPLUNK_REALM`
- `SPLUNK_ACCESS_TOKEN`

If the cluster already has Splunk OTel installed, set:

- `SKIP_SPLUNK_OTEL_INSTALL=true`
- `SPLUNK_INSTRUMENTATION_REF=<namespace>/<name>`

Example:

```bash
SKIP_SPLUNK_OTEL_INSTALL=true
SPLUNK_INSTRUMENTATION_REF=otel-splunk/splunk-otel-collector
```

### Important Defaults

The example file includes these important defaults:

- `OPENCLAW_NAMESPACE=openclaw`
- `OPENCLAW_SERVICE_NAME=openclaw`
- `OPENCLAW_DEPLOYMENT_ENVIRONMENT=Openclaw`
- `OPENCLAW_NODE_OPTIONS_BASE=--max-old-space-size=1536`
- `OPENCLAW_MEMORY_REQUEST=1Gi`
- `OPENCLAW_MEMORY_LIMIT=2Gi`

Those memory settings are not arbitrary. They were added because the initial live deployment would inject successfully but then fail to become a stable OpenClaw service under Splunk Node.js auto-instrumentation.

### Optional Cluster-Specific Overrides

- `OPENCLAW_STORAGE_CLASS`
  Set this if the cluster has no default storage class or picks the wrong one.
- `K8S_CLUSTER_NAME`
  Exported into the Splunk collector chart values.
- `K8S_DISTRIBUTION`
  Useful for values like `eks`, `gke`, or `aks`.
- `K8S_CLOUD_PROVIDER`
  Useful for values like `aws`, `gcp`, or `azure`.
- `SPLUNK_OTEL_CHART_VERSION`
  Pin the Splunk Helm chart if you need repeatable chart versioning.

## Deployment Modes

There are two intended ways to use this repo.

### Mode 1: Install Splunk OTel From This Repo

Use this when the target cluster is dedicated to the lab or does not already have a Splunk OTel operator and instrumentation object.

1. Populate `scripts/k8s/lab.env` with your OpenClaw and Splunk credentials.
2. Confirm your current Kubernetes context:

```bash
kubectl config current-context
```

3. Deploy the full lab:

```bash
scripts/k8s/deploy-lab.sh --show-token
```

This performs:

1. Splunk Collector and Operator install
2. OpenClaw deployment
3. Instrumentation annotation and rollout restart

### Mode 2: Reuse Existing Splunk OTel In The Cluster

Use this when the cluster already has a functioning Splunk OTel stack and you want to avoid installing another operator.

1. Populate `scripts/k8s/lab.env` with your OpenClaw provider key.
2. Set:

```bash
SKIP_SPLUNK_OTEL_INSTALL=true
SPLUNK_INSTRUMENTATION_REF=otel-splunk/splunk-otel-collector
```

3. Run:

```bash
scripts/k8s/deploy-lab.sh --show-token
```

This is the model that was used successfully during the live test in the cluster that already had Splunk installed.

### Mode 3: Local NemoClaw/OpenShell With OTEL

Use this when you want the real stock `nemoclaw onboard` Docker bootstrap on your machine instead of the Kubernetes lab.

1. Copy the local example file:

```bash
cp scripts/local/lab.env.example scripts/local/lab.env
```

2. Set `OPENAI_API_KEY`.
   If your machine sits behind a TLS interception proxy, also set `LOCAL_EXTRA_CA_FILE` or `LOCAL_EXTRA_CA_COMMON_NAME`.

3. If you already have a local OTEL collector in Docker exposing `4318`, nothing else is required.
   If you do not, set `SPLUNK_REALM` and `SPLUNK_ACCESS_TOKEN` so this repo can start one for you.

4. Run:

```bash
scripts/local/bootstrap-nemoclaw.sh --smoke
```

This local path does five things:

1. Reuses an existing Docker collector on `4318` or starts `openclaw-local-otel-collector` if none is found.
2. Starts a host-local OpenAI relay on `host.docker.internal:8787` unless `LOCAL_OPENAI_BASE_URL` is explicitly set.
3. Runs the stock NemoClaw onboarding flow to create the OpenShell gateway and sandbox locally.
4. Configures the OpenShell gateway and system inference routes to `openai-direct / gpt-4.1-mini` while keeping the sandbox on the stock `https://inference.local/v1` path.
5. Deploys an in-gateway OTLP forwarder service in the OpenShell k3s cluster and publishes it on `http://openclaw-otlp-forwarder.openshell.svc.cluster.local:4318`.
6. Applies a sandbox policy preset that allows that forwarder service through the OpenShell proxy, including the required `allowed_ips` override for the private service IP.
7. Restarts `openclaw gateway run` inside the sandbox with `@splunk/otel`, the host CA bundle if needed, and `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at the in-gateway forwarder service while preserving OpenShell's proxy env.

The OpenAI relay exists because some enterprise environments allow the host and the OpenShell gateway container to reach OpenAI while direct `api.openai.com` egress from sandbox pods is blocked. The OTLP forwarder exists because sandbox pods may also be unable to export directly to host ports on `4318` even though the gateway container can.

If you re-run the script against an existing sandbox, add `--recreate`.

If the sandbox already exists and you only need to reapply the OTEL-wrapped gateway restart plus a smoke prompt, use:

```bash
scripts/local/restart-nemoclaw-otel.sh --smoke
```

The local smoke path uses `openclaw agent` without `--local`. That exercises the real OpenShell gateway inference route instead of the embedded direct-provider path.

To verify the local OTEL path after bootstrap or restart, run:

```bash
scripts/local/verify-nemoclaw-otel.sh
```

If you also want to try a live agent prompt through the gateway, add:

```bash
scripts/local/verify-nemoclaw-otel.sh --smoke-agent
```

## Post-Deploy Verification

Do not stop at `kubectl get pods`. Use the full verification path.

### Basic Checks

```bash
kubectl get pods -n openclaw
kubectl get pods -n splunk-o11y
kubectl get instrumentations.opentelemetry.io -A
```

If you are reusing an existing Splunk installation in a different namespace, adjust the namespace accordingly.

### Full Verification

Run:

```bash
scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway
```

This checks:

- The deployment annotation points at the expected instrumentation object
- The pod contains the `opentelemetry-auto-instrumentation-nodejs` init container
- `NODE_OPTIONS` includes the injected auto-instrumentation bundle
- `OTEL_EXPORTER_OTLP_ENDPOINT` is present
- `OTEL_SERVICE_NAME` is present
- `OTEL_RESOURCE_ATTRIBUTES` contains `deployment.environment=Openclaw`
- The gateway is listening on port `18789`
- An authenticated localhost request to the gateway succeeds

This is the command that best represents "is the lab really working" instead of "did Kubernetes accept the manifests".

## Accessing OpenClaw

Port-forward the service:

```bash
kubectl port-forward svc/openclaw 18789:18789 -n openclaw
```

Then open:

```text
http://127.0.0.1:18789
```

To fetch the gateway token:

```bash
kubectl get secret openclaw-secrets -n openclaw -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | openssl base64 -d -A
```

## What To Expect In Splunk Observability Cloud

For the environment to appear meaningfully in Splunk APM, OpenClaw needs to generate real traces, not just carry OTEL environment variables. In practice that means:

- The gateway must be listening on `18789`
- The pod must stay alive under auto-instrumentation
- The gateway must handle at least one authenticated request

The expected OpenTelemetry identity is:

- `service.name = openclaw`
- `deployment.environment = Openclaw`

If the UI does not show the `Openclaw` environment immediately:

1. Refresh the last 15 minutes in Splunk APM.
2. Filter by service `openclaw`.
3. Re-run:

```bash
scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway
```

If that succeeds, the next likely issue is ingestion delay or the wrong UI filter, not the Kubernetes deployment.

## OpenShell Demo Path

The current repo still deploys OpenClaw directly on Kubernetes. The OpenShell / NemoClaw story is therefore implemented in two layers:

- real OpenClaw runtime health from the deployed pod
- synthetic OpenShell-style control-plane telemetry emitted over OTLP for dashboards, detectors, and scenario walkthroughs

The design and source references are in:

- `docs/openshell-demo-path.md`

Once the lab is verified, exercise the demo scenarios with:

```bash
scripts/k8s/demo-scenarios.sh normal
scripts/k8s/demo-scenarios.sh policy-blocked
scripts/k8s/demo-scenarios.sh error-burst
scripts/k8s/demo-scenarios.sh suspicious
```

Or run the full sequence:

```bash
scripts/k8s/demo-scenarios.sh all
```

The synthetic control-plane telemetry uses:

- `service.name = openshell-demo-control-plane`
- the same `deployment.environment` value as the OpenClaw pod

If the collector HTTP endpoint is not the default `${SPLUNK_OTEL_RELEASE_NAME}-agent.${SPLUNK_OTEL_NAMESPACE}.svc:4318`, set:

```bash
OPENSHELL_DEMO_COLLECTOR_URL=http://<collector-service>.<namespace>.svc:4318
```

## Troubleshooting

### Pod Is Running But Splunk Shows No OpenClaw Environment

This was the exact failure mode from the live run. The likely causes are:

- The pod was injected but the gateway was not actually listening
- The app crashed or restarted under instrumentation
- No real gateway traffic was sent, so Splunk never saw server-side spans for the service

Run:

```bash
scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway
kubectl logs deployment/openclaw -n openclaw --tail=200
```

### Gateway Never Opens Port 18789

Check the logs:

```bash
kubectl logs deployment/openclaw -n openclaw --tail=200
```

During the earlier live run, this exposed Node heap exhaustion after instrumentation injection. That is why the repo now defaults to:

- `OPENCLAW_NODE_OPTIONS_BASE=--max-old-space-size=1536`
- `OPENCLAW_MEMORY_REQUEST=1Gi`
- `OPENCLAW_MEMORY_LIMIT=2Gi`

### OpenClaw Is Reachable Only Inside The Pod

Check the OpenClaw config in:

- `scripts/k8s/manifests/configmap.yaml`

In Kubernetes, `bind: "loopback"` is wrong for this lab. The repo now uses `bind: "lan"` so the service can reach the gateway.

### PVC Does Not Bind

If the cluster has no useful default storage class, set:

```bash
OPENCLAW_STORAGE_CLASS=<your-storage-class>
```

### You Already Have Splunk OTel In The Cluster

Do not install a second operator stack unless you intend to. Reuse the existing instrumentation object with:

```bash
SKIP_SPLUNK_OTEL_INSTALL=true
SPLUNK_INSTRUMENTATION_REF=<namespace>/<name>
```

## Teardown

To remove the lab:

```bash
scripts/k8s/deploy-lab.sh --delete
```

If you reused an existing Splunk installation with `SKIP_SPLUNK_OTEL_INSTALL=true`, the delete flow removes the OpenClaw namespace but does not uninstall the reused collector stack.

If this repo installed the Splunk operator, the script removes the Helm release and namespaces. You should still review cluster-scoped resources if you are trying to return the cluster to a fully clean state.

## Skill Usage

If you are using Codex with the local skill in this repo, the matching skill is:

- `skills/openclaw-splunk-test-lab/SKILL.md`

That skill now reflects the lessons from the live cluster run and should be treated as the operational summary for how to deploy, verify, and troubleshoot this lab in future sessions.

## Recommended First Commands

If you are coming to this repo fresh, this is the shortest safe path:

```bash
cp scripts/k8s/lab.env.example scripts/k8s/lab.env
```

Edit `scripts/k8s/lab.env`, then run:

```bash
kubectl config current-context
scripts/k8s/deploy-lab.sh --show-token
scripts/k8s/verify-lab.sh --strict-gateway --smoke-gateway
kubectl port-forward svc/openclaw 18789:18789 -n openclaw
```
