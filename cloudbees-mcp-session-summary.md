# CloudBees CI MCP Router: Session Summary

**Setup:** CloudBees CI with CJOC and 10 connected controllers on EKS, queried through the CloudBees CI MCP router.

**Contents**
1. 10 general prompts
2. EKS agent scaling prompts
3. Security audit prompts
4. DORA metrics
5. Weekly combined report prompt
6. Daily check prompt
7. Simulation pipelines
8. Tips and limits

> Which prompts work depends on the tools your router exposes. Start with: "List your available tools."

---

## 1. Ten general prompts

| # | Prompt | Value |
|---|---|---|
| 1 | List all connected controllers with their status, version, and number of running builds. | Fleet health check in one answer instead of 10 UI visits. |
| 2 | Show all failed builds across all controllers in the last 24 hours, grouped by controller and job. | Fast morning triage; isolated or systemic failures. |
| 3 | Find jobs failing with the same error across multiple controllers and summarize the likely common root cause. | Spots shared causes (shared library, registry, expired credential). |
| 4 | Analyze the last 5 failed runs of pipeline X on controller Y and explain the root cause from the logs. | Replaces manual log reading; cuts time to resolution. |
| 5 | Which pipelines have the longest average duration and which stages take the most time? | Targets optimization where it saves the most time and EKS cost. |
| 6 | List all builds currently queued or stuck, with queue time and reason. | Reveals agent capacity problems (pods not scheduling, node limits). |
| 7 | Show which controllers have outdated plugins or a different version than the others. | Catches configuration drift and security risk. |
| 8 | Find pipelines that haven't run in 90 days, or jobs that always fail, across all controllers. | Cleanup candidates; less load and attack surface. |
| 9 | Which jobs use shared libraries or credentials X, and on which controllers? | Impact analysis before rotating a secret or changing a library. |
| 10 | Generate a weekly CI health report: success rate per controller, top flaky jobs, slowest pipelines, and recommendations. | Ready-made summary for reviews, with trends and actions. |

**Tip:** Start prompts with scope, such as "on controller X" or "across all controllers".

---

## 2. EKS agent scaling prompts

| # | Prompt | Value |
|---|---|---|
| 1 | Show builds that waited more than 5 minutes in the queue in the last 7 days, grouped by controller and agent label. | Shows where agent capacity is too small. |
| 2 | Which pod templates are used most, and which have the highest provisioning time before the build starts? | Finds slow-starting templates (large images, heavy init containers). |
| 3 | Find builds that failed with agent or pod errors like OOMKilled, evicted, or timeout waiting for agent. | Pinpoints wrong resource requests and limits. |
| 4 | Compare peak concurrent builds per controller by hour of day over the last 14 days. | Reveals load patterns for scheduled scaling or pre-warmed nodes. |
| 5 | Which controllers have idle executors or long-lived agents that are barely used? | Cuts wasted EKS spend; shows where ephemeral agents should replace static ones. |

Note: node-level data (Karpenter, Cluster Autoscaler) is not visible via Jenkins. Cross-check with kubectl or CloudWatch.

---

## 3. Security audit prompts

| # | Prompt | Value |
|---|---|---|
| 1 | List all plugins with known security advisories, per controller. | Prioritizes patching. |
| 2 | Which jobs and folders use credential X, and on which controllers? | Impact analysis before rotating secrets. |
| 3 | Find pipelines that run privileged containers, mount the Docker socket, or run on the built-in node. | Catches risky patterns that could lead to cluster or controller compromise. |
| 4 | Show RBAC and folder permission differences between controllers, and list users with admin rights. | Detects privilege drift. |
| 5 | List pipelines using unpinned shared library versions, `latest` image tags, or `curl \| sh` steps. | Highlights supply-chain risks and unreproducible builds. |

---

## 4. DORA metrics (partly possible)

The router exposes Jenkins build data, so you get proxies, not full DORA numbers.

| Metric | Feasible? | How |
|---|---|---|
| Deployment frequency | Good | Count successful runs of prod deploy jobs or stages |
| Lead time for changes | Partial | Commit timestamps from build changesets to deploy finish; needs SCM data on builds |
| Change failure rate | Proxy | Failed prod deploys divided by all prod deploys; real CFR also counts rollbacks and hotfixes |
| MTTR | Proxy | Failed deploy build to next successful one; real MTTR needs incident data |

**Example prompts**
1. For all jobs matching `*deploy*prod*` across all controllers, count successful runs per week for the last 90 days.
2. For the last 30 successful prod deploys of pipeline X, calculate the time from the oldest commit in the changeset to build completion.
3. What percentage of prod deploy builds failed or were aborted per controller in the last 30 days?
4. For each failed prod deploy, how long until the next successful build of the same job?
5. Summarize these four as a DORA-style report per controller, and state which numbers are proxies.

**What makes it work:** a consistent naming or folder convention for prod deploys, enough build history retention, and per-controller or per-window queries if results are capped.

---

## 5. Weekly combined report prompt (scaling + security)

```
Create a weekly CI health report for the last 7 days.
Scope: CJOC and all connected controllers. Query each controller
separately and do not skip any. If a controller or tool fails,
list it under "Data gaps".

Rules:
- Use only data returned by the tools. Never guess.
- Mark anything that is an estimate or proxy as "(proxy)".
- If data is unavailable, write "not available via MCP".

PART 1: SCALING
1. Builds queued longer than 5 minutes: count, avg and max wait,
   grouped by controller and agent label.
2. Builds failed with agent or pod errors (OOMKilled, evicted,
   timeout waiting for agent, pod provisioning failure).
3. Peak concurrent builds per controller and the busiest hour.
4. Idle or barely used executors and long-lived static agents.
5. Slowest 5 pipelines by average duration, with the slowest stage.

PART 2: SECURITY
6. Plugins with known security advisories, per controller,
   sorted by severity.
7. Plugin version drift between controllers.
8. Pipelines using privileged containers, the Docker socket,
   or the built-in node.
9. Pipelines with unpinned shared libraries, "latest" image tags,
   or "curl | sh" steps.
10. Users with admin rights per controller and RBAC differences
    between controllers.

OUTPUT FORMAT
A. Executive summary: max 5 bullets, each tagged
   [Critical] [Warning] or [OK].
B. Fleet table, one row per controller:
   | Controller | Success rate | Avg queue time | Pod errors |
   | Vulnerable plugins | Risky pipelines | Status |
C. Top 5 actions this week, ordered by impact, each with:
   what, where (controller/job), why, and effort (S/M/L).
D. Trend vs. previous week (if data is available).
E. Data gaps and assumptions.

Keep it factual and concise. No generic advice.
```

**Tips:** split into two runs if it times out; save each report and add "compare with this last report: [paste]" for trends; cross-check pod issues with kubectl or CloudWatch.

---

## 6. Daily check prompt

```
Create a daily CI health check for the last 24 hours.
Scope: CJOC and all connected controllers, queried one by one.
Use only tool data, mark proxies as "(proxy)", and write
"not available via MCP" where data is missing.

CHECK
1. Controllers: status, version, offline or unreachable ones.
2. Failed builds: count per controller, top 5 failing jobs, and
   any error that appears on more than one controller.
3. Queue: builds waiting longer than 5 minutes, with the reason
   and agent label.
4. Agent or pod errors: OOMKilled, evicted, timeout waiting
   for agent.
5. New risks: plugin advisories or config changes since yesterday
   (if available).

OUTPUT
- One-line verdict: [OK], [Warning] or [Critical].
- Table: | Controller | Status | Failed | Queued >5m | Pod errors |
- Max 3 actions for today (what, where, why).
- Data gaps, one line.

Max 20 lines. No generic advice.
```

**Follow-up:** "Analyze the last failed run of job X on controller Y and explain the root cause."

---

## 7. Simulation pipelines

Create one Pipeline job per section. All use inline YAML pod agents with public images. Create the same jobs on 2 or 3 controllers to test cross-controller findings, and put them in a folder like `sim/`.

| Pipeline | Simulates | Matches prompt area |
|---|---|---|
| 01-always-fail | Same registry error on every run | Failed builds, same error across controllers |
| 02-flaky | About 40% random failures, cron every 10 min | Top flaky jobs, success rate |
| 03-slow-pod-start | 90s init container delay | Slow pod provisioning |
| 04-queue-pressure | N parallel pods with CPU/memory requests | Queue wait, agent capacity |
| 05-oomkilled | 64Mi limit, 200M allocation | Pod errors (OOMKilled) |
| 06-bad-image | Non-existent image tag, 3 min timeout | ImagePullBackOff, agent timeout |
| 07-risky-patterns | Privileged, Docker socket, latest tag, curl \| sh text | Security pattern scan |

**Notes**
- 04 only produces real queue waits if the cluster or Kubernetes cloud container cap is reached. Raise `PODS` or run it several times at once.
- 07 may be rejected by Pod Security Admission or namespace policies. A rejected pod is still a failed build to analyze; remove the privileged and hostPath lines to run it fully.
- 05 uses the public `polinux/stress` image. If nodes can't pull it, switch to a plain shell memory loop.

**Skipped (not simulatable with a simple Jenkinsfile)**
- Plugin advisories and version drift: need actual plugin versions on controllers.
- RBAC and admin differences: controller configuration, not pipeline code.
- Idle executors and static agents: agent configuration, not a build.
- Unpinned shared libraries: need a configured global library first.
- Built-in node usage: depends on executor setup and is discouraged.
- DORA deploy metrics: not simulated yet.

### 01-always-fail

```groovy
// SIM 01: Always fails with the same error message.
// Create the same job on 2+ controllers to test "same error across controllers".
pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: main
    image: alpine:3.20
    command: ['sleep']
    args: ['99d']
'''
      defaultContainer 'main'
    }
  }
  stages {
    stage('Build') {
      steps { sh 'echo "Building..."; sleep 5' }
    }
    stage('Push image') {
      steps {
        sh '''
          echo "ERROR: failed to push to registry registry.example.internal: 401 Unauthorized (expired credential)"
          exit 1
        '''
      }
    }
  }
}
```

### 02-flaky

```groovy
// SIM 02: Flaky job, fails roughly 40% of the time.
// Trigger it 15-20 times (or add a cron trigger) to build history.
pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: main
    image: alpine:3.20
    command: ['sleep']
    args: ['99d']
'''
      defaultContainer 'main'
    }
  }
  triggers { cron('H/10 * * * *') }
  stages {
    stage('Unit tests') {
      steps {
        sh '''
          echo "Running tests..."
          sleep 10
          if [ $(( $(od -An -N1 -tu1 /dev/urandom) % 10 )) -lt 4 ]; then
            echo "FLAKY: test_checkout_timeout failed (connection reset)"
            exit 1
          fi
          echo "All tests passed"
        '''
      }
    }
  }
}
```

### 03-slow-pod-start

```groovy
// SIM 03: Slow pod start. An init container delays the agent by ~90s,
// simulating a heavy image or slow init step.
pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  initContainers:
  - name: slow-init
    image: alpine:3.20
    command: ['sh', '-c', 'echo "warming up..."; sleep 90']
  containers:
  - name: main
    image: alpine:3.20
    command: ['sleep']
    args: ['99d']
'''
      defaultContainer 'main'
    }
  }
  stages {
    stage('Work') {
      steps { sh 'echo "Agent finally started"; sleep 10' }
    }
  }
}
```

### 04-queue-pressure

```groovy
// SIM 04: Queue pressure. Starts N pods in parallel, each requesting
// real CPU/memory. Queue waits only appear if your cluster, node group
// or Kubernetes cloud "container cap" is reached.
// Increase PODS (or run this job several times at once) to force waiting.
def podYaml = '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: main
    image: alpine:3.20
    command: ['sleep']
    args: ['99d']
    resources:
      requests:
        cpu: "1"
        memory: 1Gi
'''

pipeline {
  agent none
  parameters {
    string(name: 'PODS', defaultValue: '8', description: 'Number of parallel pods')
  }
  stages {
    stage('Fan out') {
      steps {
        script {
          def branches = [:]
          for (int i = 1; i <= params.PODS.toInteger(); i++) {
            def n = i
            branches["pod-${n}"] = {
              podTemplate(yaml: podYaml) {
                node(POD_LABEL) {
                  container('main') { sh "echo pod ${n} running; sleep 120" }
                }
              }
            }
          }
          parallel branches
        }
      }
    }
  }
}
```

### 05-oomkilled

```groovy
// SIM 05: OOMKilled. The container has a 64Mi memory limit and tries to
// allocate 200M, so Kubernetes kills it.
pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: main
    image: polinux/stress
    command: ['sleep']
    args: ['99d']
    resources:
      requests:
        memory: 32Mi
      limits:
        memory: 64Mi
'''
      defaultContainer 'main'
    }
  }
  stages {
    stage('Memory hungry step') {
      steps {
        sh 'stress --vm 1 --vm-bytes 200M --vm-hang 1 --timeout 30s'
      }
    }
  }
}
```

### 06-bad-image

```groovy
// SIM 06: Bad image. The tag does not exist, so the pod ends in
// ImagePullBackOff and the build waits for an agent until the timeout.
pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: main
    image: alpine:does-not-exist-999
    command: ['sleep']
    args: ['99d']
'''
      defaultContainer 'main'
    }
  }
  options {
    // Includes agent provisioning time, so the build ends on its own.
    timeout(time: 3, unit: 'MINUTES')
  }
  stages {
    stage('Never reached') {
      steps { sh 'echo "This will not run"' }
    }
  }
}
```

### 07-risky-patterns

```groovy
// SIM 07: Risky patterns that a security scan prompt should find.
// - privileged container
// - Docker socket mounted from the host
// - "latest" image tag
// - curl | sh pattern (only echoed, NOT executed)
// NOTE: Pod Security Admission or policies on your EKS namespace may block
// privileged pods or hostPath mounts. If the pod is rejected, the build
// fails, which is still a valid test, but remove those lines to run it.
pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: main
    image: alpine:latest
    command: ['sleep']
    args: ['99d']
    securityContext:
      privileged: true
    volumeMounts:
    - name: docker-sock
      mountPath: /var/run/docker.sock
  volumes:
  - name: docker-sock
    hostPath:
      path: /var/run/docker.sock
'''
      defaultContainer 'main'
    }
  }
  stages {
    stage('Risky steps') {
      steps {
        sh '''
          echo "Simulated install step (not executed):"
          echo "curl -fsSL https://get.example.invalid/install.sh | sh"
          echo "Image tag used: alpine:latest"
        '''
      }
    }
  }
}
```

---

## 8. Tips and limits

- Scope prompts explicitly ("on controller X", "across all controllers").
- Tell Claude how to identify prod deploy jobs (name pattern, folder, stage name).
- Large result lists may be capped; query per controller or per time window.
- The router sees Jenkins data only. Use kubectl or CloudWatch for node-level EKS data, and Git or incident tools for full DORA metrics.
- If a prompt returns thin results, ask: "Which tools can answer this?"
