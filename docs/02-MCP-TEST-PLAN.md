# CloudBees CI MCP Router: Test Plan

**Setup:** CloudBees CI on EKS with an operations center (CJOC) and managed controllers, queried through the CloudBees CI MCP Router. The simulation pipelines in section 9 are created by the `controller-base` CasC bundle (`casc/controller-base/mcp/mcp-test-items.yaml`) on every controller that uses it. The folder was observed on `controller1`, `controller3`, `folder-controller1`, `folder-controller2` and `workshop` (live `getJobs`, 2026-11-10). `ASSUMPTION:` they all use `controller-base`; only the folder was observed, not the bundle assignment. `controller3` also has `05-oomkilled`, the others do not, so it may run a different bundle version.

**Status of this plan:** prompts were checked against the router's tool definitions (21 tools, 2026-11-10). Live results so far (2026-11-10): `listControllers` and `getJobs` work against the five online controllers. Earlier the same day every controller answered as `anonymous` until the controllers' trusted issuer was corrected (see Prerequisites). The prompts in sections 2 to 8 have **not** been run end to end yet.

**Tags used on every prompt**

| Tag | Meaning |
| --- | --- |
| **[Works]** | Fully answerable with the router's tools |
| **[Partial]** | Answerable with limits, or only through a proxy. The limit is stated |
| **[N/A]** | No router tool can answer it. Moved to [Appendix A](#appendix-a-not-available-via-the-router) |

**Contents**

1. Tool reference
2. Smoke tests (read-only)
3. General prompts
4. EKS agent scaling prompts
5. Security audit prompts
6. Weekly report prompt
7. Daily check prompt
8. Write-tool tests
9. Simulation pipelines
10. Tips and limits
11. Appendix A: not available via the router

---

## Prerequisites

1. Ask: "List your available tools." Expect the 21 tools in section 1.
2. Ask: "Who am I?" (`whoAmI`). Expect your user name from every online controller. If it returns `anonymous is missing the Overall/Read permission`, the controllers are not accepting the exchanged token and every prompt below returns no data. Fix that first (see [MCP.md](MCP.md), Troubleshooting). A quick check: `curl https://<host>/<controller>/.well-known/oauth-protected-resource` must show a full host in `authorization_servers`, not `https:///...`.
3. Offline controllers can slow or time out unfiltered calls. Use `listControllers`, then pass `controllerNames` for the online ones.

---

## 1. Tool reference

All tools except `listControllers` (which filters with `names`) and `getRouterStatus` accept `controllerNames` (comma-separated controller names from `listControllers`). **Omitting it queries every controller you can access.** `getJobs` and `findJobsWithScmUrl` return at most 10 items per call (use `skip` to page). Most read tools accept `tree`, the Jenkins Remote API field selector, to limit the response.

| Area | Tools | What they answer |
| --- | --- | --- |
| Router and identity | `getRouterStatus`, `whoAmI` | Router health, the identity used per controller |
| Topology and health | `listControllers`, `getStatus` | Controller name, path, core version, state, online/offline/hibernated; quiet mode, admin monitors, queue size, executor capacity |
| Jobs | `getJobs`, `getJob`, `getJobScm`, `findJobsWithScmUrl` | Job lists (10 per page), job details, SCM config, jobs by Git URL |
| Builds | `getBuild`, `getBuildLog`, `searchBuildLog`, `getBuildScm`, `getBuildChangeSets` | Build result and duration, log lines (last 100 by default), regex log search, SCM data, changes |
| Tests | `getTestResults`, `getFlakyFailures` | Test reports and flaky failures (need a test report on the build) |
| Queue | `getQueueItem` | One queue item by id (no queue listing) |
| Pipeline scripts | `getReplayScripts` | Main and loaded scripts of a Pipeline build |
| Write actions | `triggerBuild`, `rebuildBuild`, `replayBuild`, `updateBuild` | Start, re-run, replay with a changed script, rename a build |

Not exposed: plugins and advisories, users and RBAC, credentials, agents and pods, queue history, stage timings.

---

## 2. Smoke tests (read-only)

Run these in order after the prerequisites. Job names come from the simulation pipelines in section 9. Jobs must have run at least once to return builds.

| # | Prompt | Tool | Expected |
| --- | --- | --- | --- |
| S1 | Who am I on controller1? | `whoAmI` (`controllerNames=controller1`) | Your user name, not `anonymous` |
| S2 | Is the MCP router healthy? | `getRouterStatus` | "operational and ready" |
| S3 | List all controllers with state, status and version. | `listControllers` | One row per controller; offline ones listed as `offline` |
| S4 | Show the health of controller1, controller3, folder-controller1 and folder-controller2: quiet mode, admin monitors, queue size, executors. | `getStatus` | Status block per controller |
| S5 | List the jobs in folder `mcp-test-pipeline` on controller1. | `getJobs` (`parentFullName=mcp-test-pipeline`) | Jobs `01`-`04`, `06`, `07` (`05` is disabled in the bundle; `controller3` still has it) |
| S6 | Show job `mcp-test-pipeline/01-always-fail` on controller1. | `getJob` | Last build, health report |
| S7 | Show build 1 of that job, then the last build. | `getBuild` | Result `FAILURE`, duration |
| S8 | Show the last 50 log lines of that build. | `getBuildLog` (`limit=-50`) | The registry `401` error message |
| S9 | Search that log for `ERROR` with 2 lines of context. | `searchBuildLog` (`pattern=ERROR`, `contextLines=2`) | The `ERROR: failed to push` line |
| S10 | Show the pipeline script of the last build of `mcp-test-pipeline/07-risky-patterns`. | `getReplayScripts` | Script with the pod YAML |
| S11 | Show the SCM config and changes of `mcp-test-pipeline/01-always-fail`. | `getJobScm`, `getBuildScm`, `getBuildChangeSets` | Empty (the jobs are inline, not SCM-backed) |
| S12 | Which jobs use the Git URL `https://git.example.com/my-org/my-repo.git`? | `findJobsWithScmUrl` | No match (no SCM-backed sim exists yet) |
| S13 | Show test results and flaky failures of `mcp-test-pipeline/02-flaky`. | `getTestResults`, `getFlakyFailures` | Empty (the sims publish no test report) |

S11 to S13 prove the tools respond. They only return data once SCM-backed or test-reporting jobs exist.

---

## 3. General prompts

| # | Prompt | Tag | Tool(s) and notes |
| --- | --- | --- | --- |
| G1 | For controller1, controller3, folder-controller1 and folder-controller2, show status, core version and executor capacity. | **[Partial]** | `listControllers` + `getStatus`. A running-build count is not returned; use `getJob` with `tree=lastBuild[building]` per job as a proxy |
| G2 | On controller1, controller3, folder-controller1 and folder-controller2, list jobs in `mcp-test-pipeline` whose last build failed, with the build time. | **[Partial]** | `getJobs` with `tree=name,fullName,lastBuild[number,result,timestamp]`. Last build only; "last 24 hours" is filtered by the agent from `timestamp` |
| G3 | Search the last build log of `mcp-test-pipeline/01-always-fail` on all controllers for `registry.example.internal: 401`, and say whether the same error occurs on more than one controller. | **[Works]** | `searchBuildLog` without `controllerNames`. Each result is tagged with its controller |
| G4 | Show the last 5 builds of `mcp-test-pipeline/02-flaky` on controller1 (result, duration), then find the failing line in each failed build's log. | **[Works]** | `getJob` with `tree=builds[number,result,duration]{0,5}`, then `searchBuildLog` (`pattern=FLAKY`). `ASSUMPTION:` the `{0,5}` range syntax works through the router; not verified |
| G5 | Rank the jobs in `mcp-test-pipeline` by average duration of their last 10 builds. | **[Partial]** | `getJob` with `tree=builds[duration]{0,10}` per job. Job level only; stage durations are not available |
| G6 | Is any job in `mcp-test-pipeline` waiting in the queue right now, and why? | **[Partial]** | `getStatus` for the queue size; `getJob` with `tree=inQueue,queueItem[id,why,inQueueSince]`, then `getQueueItem`. `ASSUMPTION:` `queueItem` is returned by the job tree. Current queue only, no history |
| G7 | Do the controllers run different core versions? | **[Partial]** | `listControllers` (`lastKnownVersion`). Core version only; plugin versions are not available |
| G8 | List jobs on controller1 whose last build is older than 90 days, or that failed every time. | **[Partial]** | `getJobs` with `tree=name,fullName,lastBuild[number,result,timestamp]`, paged with `skip`. 10 jobs per call |
| G9 | Which Pipeline jobs on controller1 use `@Library` or `credentialsId` X? | **[Partial]** | `getReplayScripts` per job, then the agent scans the text. Pipeline jobs with at least one build only |
| G10 | Generate a weekly CI health report. | **[Partial]** | See section 6 |

**Tip:** start prompts with scope, such as "on controller1" or "on controller1 and controller3".

---

## 4. EKS agent scaling prompts

| # | Prompt | Tag | Tool(s) and notes |
| --- | --- | --- | --- |
| SC1 | Which builds waited more than 5 minutes in the queue in the last 7 days? | **[N/A]** | No queue history. See Appendix A |
| SC2 | Compare the duration of `03-slow-pod-start` with `01-always-fail` on controller1 to estimate pod start delay. | **[Partial]** | `getJob` with `tree=builds[duration]{0,5}`. Proxy only (`03` should take about 90 s longer). Mark as "(proxy)" |
| SC3 | Search the last build log of `06-bad-image` on controller1 for `ImagePullBackOff\|ErrImagePull\|Still waiting\|timeout`. | **[Partial]** | `searchBuildLog` (`useRegex=true`). `ASSUMPTION:` the Kubernetes plugin writes these strings to the build log. For `05-oomkilled` use `OOMKilled\|137` once that job is enabled |
| SC4 | Compare peak concurrent builds per controller by hour. | **[N/A]** | No concurrency history. See Appendix A |
| SC5 | Show executor capacity per controller. | **[Partial]** | `getStatus`. Capacity totals only; there is no per-agent list |

Node-level data (Karpenter, Cluster Autoscaler) is not visible via Jenkins. Cross-check with kubectl or CloudWatch.

---

## 5. Security audit prompts

| # | Prompt | Tag | Tool(s) and notes |
| --- | --- | --- | --- |
| SE1 | List all plugins with known security advisories. | **[N/A]** | No plugin tool. See Appendix A |
| SE2 | Which Pipeline jobs use credential X? | **[Partial]** | Same as G9 |
| SE3 | Show the pipeline script of `mcp-test-pipeline/07-risky-patterns` and list privileged containers, Docker socket mounts, `hostPath` volumes, `latest` image tags and `curl \| sh` lines. | **[Partial]** | `getReplayScripts`, then the agent scans the text. Built-in node usage is not available |
| SE4 | Show RBAC differences between controllers and the users with admin rights. | **[N/A]** | `whoAmI` returns only your own identity. See Appendix A |
| SE5 | Across all Pipeline jobs in `mcp-test-pipeline`, list `@Library` references without a pinned version, `latest` tags and `curl \| sh`. | **[Partial]** | `getJobs`, then `getReplayScripts` per job |

---

## 6. Weekly report prompt

Only questions the tools can answer are in the prompt. The rest is listed under "Data gaps" automatically.

```
Create a weekly CI health report for the last 7 days.
Scope: controllers controller1, controller3, folder-controller1 and
folder-controller2, folder
mcp-test-pipeline. Query each controller separately with
controllerNames. Page getJobs with skip (max 10 per call).
If a controller or tool fails, list it under "Data gaps".

Rules:
- Use only data returned by the tools. Never guess.
- Mark anything that is an estimate or proxy as "(proxy)".
- If data is unavailable, write "not available via MCP".

DATA TO COLLECT
1. listControllers + getStatus: state, core version, queue size,
   executor capacity per controller.
2. getJobs (tree=name,fullName,lastBuild[number,result,timestamp]):
   jobs whose last build failed.
3. getJob (tree=builds[number,result,duration,timestamp]{0,20}) per
   job: success rate and average duration.
4. searchBuildLog on failed builds: errors seen on more than one
   controller, and pod errors (ImagePullBackOff, OOMKilled,
   "Still waiting").
5. getReplayScripts per job: privileged containers, Docker socket,
   latest tags, "curl | sh", unpinned @Library.
6. getFlakyFailures per job (if test results exist).
Always write "not available via MCP" for: plugin advisories, plugin
drift, RBAC and admin users, queue wait history, peak concurrency.

OUTPUT FORMAT
A. Executive summary: max 5 bullets, each tagged
   [Critical] [Warning] or [OK].
B. Fleet table, one row per controller:
   | Controller | Status | Success rate | Avg duration | Pod errors |
   | Risky pipelines |
C. Top 5 actions this week, ordered by impact, each with:
   what, where (controller/job), why, and effort (S/M/L).
D. Data gaps and assumptions.

Keep it factual and concise. No generic advice.
```

**Tips:** split into two runs if it times out; save each report and add "compare with this last report: [paste]" for trends.

---

## 7. Daily check prompt

```
Create a daily CI health check for the last 24 hours.
Scope: controller1, controller3, folder-controller1 and
folder-controller2, folder mcp-test-pipeline,
queried one by one with controllerNames.
Use only tool data, mark proxies as "(proxy)", and write
"not available via MCP" where data is missing.

CHECK
1. listControllers + getStatus: state, version, offline or
   unreachable controllers, queue size.
2. getJobs: jobs whose last build failed in the last 24 hours, and
   any error (searchBuildLog) that appears on more than one
   controller.
3. getJob (tree=inQueue,queueItem[why,inQueueSince]): jobs waiting
   in the queue now, with the reason.
4. searchBuildLog on failed builds: ImagePullBackOff, OOMKilled,
   "Still waiting".

OUTPUT
- One-line verdict: [OK], [Warning] or [Critical].
- Table: | Controller | Status | Failed | Queued now | Pod errors |
- Max 3 actions for today (what, where, why).
- Data gaps, one line.

Max 20 lines. No generic advice.
```

**Follow-up:** "Analyze the last failed run of `mcp-test-pipeline/01-always-fail` on controller1 and explain the root cause."

---

## 8. Write-tool tests

These tools change state. Run them only on `mcp-test-pipeline` jobs, and **always pass `controllerNames`**: omitting it sends the call to every accessible controller. Your agent must ask for confirmation before each call. Do not trigger `07-risky-patterns`, and keep `04-queue-pressure` to `PODS=2` here because it requests 1 CPU and 1Gi per pod.

| # | Prompt | Tool | Expected |
| --- | --- | --- | --- |
| W1 | Trigger `mcp-test-pipeline/01-always-fail` on controller1 only. | `triggerBuild` (`controllerNames=controller1`) | A queue item; follow it with `getQueueItem`, then `getBuild` |
| W2 | Trigger `mcp-test-pipeline/04-queue-pressure` on controller1 with `PODS=2`. | `triggerBuild` (`parameters={"PODS":"2"}`) | A queue item; `PODS` is a string parameter |
| W3 | Rebuild the last build of `mcp-test-pipeline/01-always-fail` on controller1. | `rebuildBuild` | A new build with the same parameters |
| W4 | Set the display name of the last build of `01-always-fail` on controller1 to `mcp-test` and the description to `router test`. | `updateBuild` | Updated name and description (`getBuild` to confirm) |
| W5 | Show the script of the last build of `01-always-fail` on controller1, then replay it with the error text changed. | `getReplayScripts`, `replayBuild` | A new build that fails with the changed message |

---

## 9. Simulation pipelines

**Source of truth:** `casc/controller-base/mcp/mcp-test-items.yaml`. The folder `mcp-test-pipeline` (group `developers`, user `dev1`, role `develop`) is created on every controller that uses `controller-base` (observed on all five online controllers), so they get identical jobs, which allows "same error across controllers" tests. Use the Groovy below only to create the jobs by hand on other controllers. All jobs use inline YAML pod agents with public images.

| Pipeline | Simulates | Matches prompt |
| --- | --- | --- |
| 01-always-fail | Same registry error on every run | G2, G3 |
| 02-flaky | About 40% random failures, cron every 10 min | G4, G5 |
| 03-slow-pod-start | 90s init container delay | SC2 |
| 04-queue-pressure | N parallel pods with CPU/memory requests | G6, W2 |
| 05-oomkilled | 64Mi limit, 200M allocation. **Commented out in the bundle** | SC3 |
| 06-bad-image | Non-existent image tag, 3 min timeout | SC3 |
| 07-risky-patterns | Privileged, Docker socket, latest tag, curl \| sh text | SE3, SE5 |

**Notes**

- Validate in a test environment first: `02-flaky` runs on a schedule and `04-queue-pressure` consumes cluster capacity.
- 04 only produces real queue waits if the cluster or Kubernetes cloud container cap is reached. Raise `PODS` or run it several times at once.
- 07 may be rejected by Pod Security Admission or namespace policies. A rejected pod is still a failed build to analyze; remove the privileged and hostPath lines to run it fully.
- 05 uses the public `polinux/stress` image. To enable it, uncomment it in `mcp-test-items.yaml` and bump the bundle `version`. If nodes can't pull the image, switch to a plain shell memory loop.
- No sim publishes a test report or uses SCM, so `getTestResults`, `getFlakyFailures`, `getBuildScm` and `getBuildChangeSets` return empty (smoke tests S11 to S13).

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

## 10. Tips and limits

- Scope prompts explicitly ("on controller1", "on controller1 and controller3", or by name for any of the four) and pass `controllerNames` for anything that changes state.
- Tell your agent how to identify prod deploy jobs (name pattern, folder, stage name) if you add DORA-style questions.
- `getJobs` returns at most 10 jobs per call. Large fleets need paging (`skip`) or per-folder queries.
- Use `tree` to cut response size (for example `lastBuild[number,result,timestamp]`).
- Offline or hibernated controllers can make unfiltered calls time out. Check `listControllers` first.
- The router sees Jenkins data only. Use kubectl or CloudWatch for node-level EKS data, and Git or incident tools for full DORA metrics.
- If a prompt returns thin results, run `whoAmI` first (anonymous sessions return little), then ask: "Which tools can answer this?"

---

## Appendix A: not available via the router

| Question | Why | Where to look instead |
| --- | --- | --- |
| Plugin advisories and plugin version drift (G7 part, SE1) | No plugin tool | Operations center and controller Plugin Manager, CloudBees Assurance Program, `casc/*/plugins.yaml` |
| RBAC differences and admin users (SE4) | No users or RBAC tool | Operations center RBAC (`casc/cjoc/rbac.yaml`), the Jenkins UI |
| Builds that waited in the queue, queue history (SC1) | `getQueueItem` takes one id; no history | Controller metrics (Prometheus), Jenkins Metrics plugin |
| Pod template usage and provisioning time (SC2 part) | No agent or pod data | `kubectl get events`, Kubernetes plugin logs, CloudWatch |
| Peak concurrent builds by hour (SC4) | No concurrency history | Metrics, or timestamps of every build (expensive and approximate) |
| Idle agents, built-in node usage (SC5, SE3 part) | No per-agent data | Node configuration, `kubectl` |
| Stage-level durations (G5 part) | No stage data | Pipeline Stage View or the Blue Ocean / REST `wfapi` |
| Credential usage in non-Pipeline jobs (G9, SE2) | Only Pipeline scripts are readable | Credentials usage tracking in the Jenkins UI |
| DORA deployment metrics | Not simulated, no Git or deploy data | Git, deployment and incident tools |
