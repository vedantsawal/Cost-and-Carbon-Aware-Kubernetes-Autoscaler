
# Cost-and-Carbon-Aware-Kubernetes-Autoscaler

### CS218 – Final Project  
**By:** Vedant Sawal and Hina Dawar  

---

## Overview
This project implements a **cost- and carbon-aware autoscaler** that extends Kubernetes beyond CPU-based scaling.  
It integrates **Prometheus metrics**, **OpenCost cost data**, and **carbon intensity APIs** to make intelligent scaling decisions.  
The goal is to dynamically balance **performance, cost efficiency, and sustainability** in real time.

---

## Concept
Traditional Kubernetes autoscalers scale purely on CPU or traffic load.  
They ignore cloud cost variations and regional energy mix, leading to waste and emissions.  

Our autoscaler introduces a **closed feedback loop** that:
- Monitors workload health and latency (Prometheus)
- Tracks live cloud spend (OpenCost)
- Reads grid carbon intensity (ElectricityMaps or WattTime)
- Adjusts workloads through Karpenter, HPA, and KEDA  
to achieve the *cheapest and cleanest* configuration that still meets SLOs.

---

## Architecture
The architecture is divided into the following layers:

- **Metrics & Signals:** Prometheus, OpenCost, Carbon API  
- **Decision Logic:** Policy engine for Peak and Off-Peak operations  
- **Actuation:** HPA, KEDA, and Karpenter for pod and node scaling  

Cluster setup scripts:
```bash
00_common.sh               # shared environment variables and helpers
01_cluster.sh              # initializes 3-node EKS cluster
02_pod_identity_cni.sh     # configures networking (CNI)
03_monitoring.sh           # installs Prometheus + Grafana stack
04_kyverno.sh              # optional security policy engine (not used)
05_karpenter.sh            # installs Karpenter autoscaler
06_opencost.sh             # installs OpenCost for cost tracking
```

## Demo Workflow

Demo scripts validate scaling and monitoring behavior in real time.

```bash
./demo_18_preroll_check.sh       # Verify environment and cleanup
./demo_40_watch_observe.sh       # Launch observability stack (Grafana/OpenCost)
./demo_20_offpeak_configure.sh   # Apply Off-Peak policy (Spot-preferred)
./demo_21_peak_configure.sh      # Apply Peak policy (On-Demand priority)
./demo_30_burst_configure.sh     # Simulate burst workload and autoscaling
./demo_41_observe_cost_nodes.sh  # Summarize node pool, cost, and carbon data
```

## Visualization

**Grafana:** [http://127.0.0.1:3000](http://127.0.0.1:3000)  
Tracks metrics such as node count, pods per node, latency, and workload phases.

**OpenCost:** [http://127.0.0.1:9090](http://127.0.0.1:9090)  
Displays live cost distribution between Spot and On-Demand pools.


