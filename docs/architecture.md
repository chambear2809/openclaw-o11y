# OpenClaw O11y Architecture

This document captures the current architecture implemented in this repository.

Two paths exist today:

- The Kubernetes lab is the primary deployed runtime in this repo. It runs a real `openclaw` service, uses Splunk operator-based Node.js auto-instrumentation, and can emit additional synthetic OpenShell-shaped control-plane telemetry for demos.
- The local NemoClaw/OpenShell path is the real OpenShell runtime flow. It uses a host-local collector, a host-local OpenAI relay, and an in-gateway OTLP forwarder so sandboxed OpenClaw can export telemetry reliably.

Conventions used in the diagrams:

- Solid arrows show runtime request flow or telemetry export flow.
- Dashed arrows show setup, orchestration, or auto-instrumentation injection.
- Any path labeled `synthetic` is demo-generated telemetry rather than native OpenShell runtime telemetry.

## System Overview

```mermaid
flowchart TB
  User[Operator or demo user]
  Splunk[Splunk Observability Cloud]
  OpenAI[OpenAI API]

  subgraph K8s["Kubernetes Lab"]
    direction TB
    K8sOp[Splunk OTel Operator and Instrumentation]
    K8sSvc[openclaw Service]
    K8sPod[openclaw Pod]
    K8sDemo[Synthetic OpenShell-shaped control-plane telemetry]
    K8sCollector[Splunk OTel Collector components]

    User -->|real gateway traffic| K8sSvc
    K8sSvc --> K8sPod
    K8sOp -.-> K8sPod
    K8sPod -->|real runtime traces| K8sCollector
    K8sDemo -->|synthetic traces, metrics, logs| K8sCollector
  end

  subgraph Local["Local NemoClaw and OpenShell"]
    direction TB
    LocalBootstrap[bootstrap-nemoclaw flow]
    Gateway[OpenShell gateway]
    Sandbox[Sandboxed OpenClaw]
    Relay[Host-local OpenAI relay]
    Forwarder[In-gateway OTLP forwarder]
    LocalCollector[Host-local OTEL collector]

    LocalBootstrap -.-> Gateway
    Gateway --> Sandbox
    Gateway -->|provider traffic| Relay
    Relay --> OpenAI
    Sandbox -->|real OTLP telemetry| Forwarder
    Forwarder --> LocalCollector
    Relay -->|real relay telemetry| LocalCollector
  end

  K8sCollector --> Splunk
  LocalCollector --> Splunk
```

## Kubernetes Lab Detail

This is the primary current-state deployment path in the repo. The OpenClaw gateway is real. The OpenShell-shaped control-plane telemetry is synthetic and is added by the demo scenario flow.

```mermaid
flowchart LR
  User[User or smoke test]
  Splunk[Splunk Observability Cloud]

  subgraph Cluster["Kubernetes cluster"]
    direction LR

    subgraph OpenClawNS["openclaw namespace"]
      direction TB
      Svc[Service openclaw]
      Pod[Deployment and Pod openclaw]
      Demo[Demo emitter inside openclaw pod context]
    end

    subgraph SplunkNS["splunk-o11y namespace or existing Splunk namespace"]
      direction TB
      Operator[OpenTelemetry Operator]
      Instr[Instrumentation resource]
      Agent[Splunk OTel agent]
      ClusterReceiver[Cluster receiver]
    end

    User -->|HTTP 18789| Svc
    Svc --> Pod
    Operator -.-> Instr
    Instr -.-> Pod
    Pod -->|real OpenClaw traces| Agent
    ClusterReceiver -->|k8s infra telemetry| Splunk
    Demo -->|synthetic control-plane traces, metrics, logs| Agent
  end

  DeployLab[scripts/k8s/deploy-lab.sh] -.-> Operator
  DeployLab -.-> Pod
  DemoScenarios[scripts/k8s/demo-scenarios.sh] -.-> Demo

  Agent --> Splunk
```

Key points for this path:

- `scripts/k8s/deploy-lab.sh` orchestrates Splunk OTel install or reuse, OpenClaw deployment, and the final instrumentation reference.
- `scripts/k8s/verify-lab.sh` validates the pod mutation, injected OTEL env, gateway listener, and authenticated smoke request.
- `scripts/k8s/demo-scenarios.sh` adds the synthetic `openshell-demo-control-plane` telemetry used for dashboards and detectors.

## Local NemoClaw and OpenShell Detail

This is the real OpenShell runtime path in the repo. The sandboxed gateway flow is real, and the OTLP forwarder exists so sandboxed OpenClaw can export telemetry to a gateway-reachable service instead of a host port.

```mermaid
flowchart LR
  User[Local operator]
  Splunk[Splunk Observability Cloud]
  OpenAI[OpenAI API]

  subgraph Host["Developer machine"]
    direction LR
    Bootstrap[scripts/local/bootstrap-nemoclaw.sh]
    Collector[Host-local OTEL collector]
    Relay[Host-local OpenAI relay]
  end

  subgraph GatewayCluster["OpenShell gateway container and in-container k3s"]
    direction TB
    Gateway[OpenShell gateway]
    Sandbox[Sandboxed OpenClaw runtime]
    Forwarder[openclaw-otlp-forwarder service]
  end

  User -->|UI or agent traffic| Gateway
  Gateway --> Sandbox
  Gateway -->|OpenAI-compatible provider calls| Relay
  Relay --> OpenAI
  Sandbox -->|OTLP HTTP via proxy| Forwarder
  Forwarder --> Collector
  Relay -->|relay service telemetry| Collector
  Collector --> Splunk

  Bootstrap -.-> Gateway
  Bootstrap -.-> Forwarder
  Bootstrap -.-> Sandbox
```

Key points for this path:

- `scripts/local/ensure-collector.sh` reuses a compatible local collector or starts a repo-owned one.
- `scripts/local/ensure-openai-relay.sh` provides a gateway-reachable host relay when direct provider egress is constrained.
- `scripts/local/ensure-gateway-otlp-forwarder.sh` deploys the in-gateway forwarder that bridges sandbox OTLP traffic to the host collector.
- `scripts/local/verify-nemoclaw-otel.sh` verifies collector reachability, relay health, forwarder health, gateway OTEL env, and optional smoke-agent flows.

## Related Docs

- [README.md](../README.md) for deployment modes, prerequisites, and verification commands.
- [openshell-demo-path.md](./openshell-demo-path.md) for the demo telemetry contract, dashboard shape, and detector shape.
