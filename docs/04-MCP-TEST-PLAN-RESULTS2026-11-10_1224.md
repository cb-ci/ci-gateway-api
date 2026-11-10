# MCP Test Plan Results

**Run:** 2026-11-10, 11:56 to 12:24 UTC, through the CloudBees CI MCP Router as user `user-a`.
**Plan:** [MCP-TEST-PLAN.md](MCP-TEST-PLAN.md)
**Scope:** online controllers `controller1`, `controller3`, `folder-controller1`, `folder-controller2` and `workshop`. `controller2` is DEPROVISIONED and `hahs`, `plugable-storage`, `plugins-casc-uc` and `testnodegroup` are offline, so none were exercised.

**Legend:** **Pass** = returned the expected data. **Pass (limits)** = returned data with the limits noted. **Fail** = wrong or no result. **N/A** = no router tool can answer it. **Not run** = skipped on purpose.

## Summary

| Result | Count |
| --- | --- |
| Pass | 20 |
| Pass (limits) | 15 |
| Fail | 1 (S11: `getBuildScm` NPE) |
| N/A (confirmed) | 2 (SE1, SE4) |
| Not run | 2 (SC4, W2) |

40 prompts in scope: 38 executed, 2 not run. S11 is counted as Fail because one of its three tools errors. The G4 "find failing line in each log" step was not run (noted in its row).

### Key findings

| # | Finding | Evidence | Suggestion |
| --- | --- | --- | --- |
| 1 | **`getBuildScm` throws `NullPointerException`** for a build with no SCM | S11, `controller1`, `01-always-fail` #1. `getJobScm` and `getBuildChangeSets` correctly return "no results" | Report to the MCP Server plugin maintainers. Until fixed, call `getJobScm` first and skip `getBuildScm` for inline pipelines |
| 2 | **`04-queue-pressure` does not fan out** | The replay script on `folder-controller1` shows `branches["pod-"]` and `echo pod  running`. In `casc/controller-base/mcp/mcp-test-items.yaml` lines 182 and 185 the `${n}` is not escaped, so CasC replaces it with an empty string. Every branch gets the same key, so only one pod runs | Escape the variable as `^${n}` in `mcp-test-items.yaml` (CasC escape), bump the controller bundle version, and re-check with `getReplayScripts` |
| 3 | **`06-bad-image` does not stop after its 3-minute timeout** | Build #1 (`controller1`) and #3 (`controller3`) were still `building` 13 minutes after start. The plan's note says the timeout "includes agent provisioning time" | `ASSUMPTION:` the declarative `options { timeout }` starts only after the agent is allocated. Wrap the pod-requesting step in a `timeout` that starts earlier, or set a pod connect timeout, and fix the comment in the plan and bundle |
| 4 | **`getStatus` does not show Kubernetes capacity** | "Defined clouds" is `[]` and "Available executors" is `0` or `1` on every controller, yet Kubernetes agent builds ran fine | Do not use `getStatus` to judge agent capacity. This corrects my earlier inference that builds could not start |
| 5 | **Intermittent upstream timeouts** | `triggerBuild` timed out on its first attempt twice (01-always-fail, controller1 and controller3). `whoAmI` and `getJobs` each timed out once. In every trigger case I confirmed no build had started before retrying | Always check `nextBuildNumber` or the queue before retrying a write call |
| 6 | **`07-risky-patterns` ran successfully** | `folder-controller1` and `folder-controller2` show build #2 `SUCCESS`. The privileged pod and Docker socket mount were admitted | Treat this as a real cluster finding. Check Pod Security Admission on the agent namespace |
| 7 | **`controller3` differs from the other controllers** | It has `05-oomkilled`, the others do not | Check which bundle version `controller3` runs |
| 8 | **`04-queue-pressure` shows a 6-day duration** | `folder-controller1` and `folder-controller2` #1 report `duration` 518,724,744 ms with result `SUCCESS` | Probably a stale or interrupted run. Check before using it as a baseline |
| 9 | **Queue waits are available per build** | `getBuild` with `tree=actions[waitingDurationMillis,buildableDurationMillis,blockedDurationMillis,executingTimeMillis]` returned a `TimeInQueueAction` | Upgrade plan item SC1 from N/A to Partial (per-build wait, not a fleet query) |

## Results by prompt

### Smoke tests

| Prompt | Results | Issues | Suggestion | Value provided by MCP |
| --- | --- | --- | --- | --- |
| **S1** Who am I on controller1? | **Pass.** `user-a` on all 5 online controllers | One earlier single-controller call timed out | Retry once, then check the router with S2 | Confirms the OAuth chain end to end in one call |
| **S2** Is the router healthy? | **Pass.** "operational and ready" | None | None | Separates router faults from controller faults |
| **S3** List all controllers | **Pass.** 11 controllers: 5 online, 6 offline, all versions and states | The first attempt that day timed out | None | Fleet topology in one call instead of a UI tour |
| **S4** Health of 4 controllers | **Pass.** Quiet mode `false`, 6 admin monitors on each, root URL `OK`, queue size 1/1/0/0, executors 1/1/0/0 | "Defined clouds" is always `[]` (finding 4) | Do not use for capacity | Surfaces the admin monitors (for example "Non-CAP Plugins Monitor") without opening each controller |
| **S5** Jobs in `mcp-test-pipeline` on controller1 | **Pass.** `01`-`04`, `06`, `07` as expected | None | None | Folder-level job listing with last-build result |
| **S6** Show job 01-always-fail | **Pass.** Health score 0 ("All recent builds failed"), `color: red` | None | None | Job health without opening the UI |
| **S7** Show build 1 | **Pass.** `FAILURE`, 17,865 ms, `building: false` | None | None | Exact result and duration per build |
| **S8** Last 50 log lines | **Pass.** Lines 70-119 including `ERROR: failed to push to registry ... 401` | None | None | Reads the tail of a log (errors are usually at the end) |
| **S9** Search log for `ERROR` | **Pass.** 3 matches with 2 lines of context | None | None | Targeted search without downloading the whole log |
| **S10** Pipeline script of 07 | **Pass.** Full script returned (taken from `folder-controller1`, build #2, because `controller1` has no 07 build) | `controller1` and `controller3` never built 07 | Run 07 once on every controller you test | Script text enables security scans without Git access |
| **S11** SCM config and changes | **Fail (partial).** `getJobScm` and `getBuildChangeSets`: "no results". `getBuildScm`: `NullPointerException` | Finding 1 | See finding 1 | Safe, empty result for inline jobs apart from the NPE |
| **S12** Jobs by Git URL | **Pass.** No match on `controller1` and `controller3` | No SCM-backed job exists to prove a positive match | Add an SCM-backed sim | Reverse lookup from repository to jobs |
| **S13** Test results, flaky failures | **Pass.** Both return "no results" | Sims publish no test report | Add a JUnit-reporting sim | Tools respond correctly when no report exists |

### General prompts

| Prompt | Results | Issues | Suggestion | Value provided by MCP |
| --- | --- | --- | --- | --- |
| **G1** Status, version, executors | **Pass (limits).** All online: core `2.580.2.38435`. Queue 1/1/0/0, executors 1/1/0/0 at run time | No running-build count (as the plan says) | Use `getJob` with `tree=lastBuild[building]` as a proxy | One answer for 4 to 5 controllers |
| **G2** Last build failed, with time | **Pass (limits).** Failed last builds: `01-always-fail` on all 4 controllers; `02-flaky` on `controller1` (#3). Folder-controller builds date from 2026-10-30 | Last build only; "24 hours" is filtered by the agent | Use `builds[...]{0,N}` when history matters | Cross-controller failure triage |
| **G3** Same error across controllers | **Pass.** One call without `controllerNames` returned the `registry.example.internal: 401` line from all 5 online controllers, with no timeout from offline ones | None | Keep this prompt as the headline demo | Finds a shared root cause across controllers in one call |
| **G4** Last 5 builds of 02-flaky, failing line | **Pass (limits).** The `builds[...]{0,5}` range syntax works: `controller1` #1 FAIL 33.9 s, #2 FAIL 14.6 s; `controller3` #59 and #60 SUCCESS | The "find failing line in each log" step was not run | Confirm the assumption in the plan is now verified | History and results in one call |
| **G5** Rank jobs by duration | **Pass (limits).** 03-slow-pod-start 104-143 s (and 267 s for the first folder-controller runs), 02-flaky 14-34 s, 01-always-fail 10-18 s, 04 shows 6 days (finding 8) | Job level only, no stages | Pull stage timings from another source | Fast optimization targets |
| **G6** Anything queued now | **Pass.** `getJob` tree `queueItem` is `null` when empty; `getQueueItem` returns the finished item, including `TimeInQueueAction` (waiting 4 ms) | The plan's `queueItem` assumption is now verified | Mark G6 as verified | Queue state and per-item wait |
| **G7** Core version drift | **Pass (limits).** No drift among online controllers (all `2.580.2.38435`). `folder-controller1` moved from 2.568.3.37913 to 2.580.2.38435 during the session. Offline: `hahs` 2.580.2.38434, `plugable-storage` and `plugins-casc-uc` 2.580.1.38223 | Core version only, no plugin versions | Use the Plugin Manager or `plugins.yaml` for plugins | Spots version skew quickly |
| **G8** Jobs older than 90 days or always failing | **Pass (limits).** No job older than 90 days; oldest last build is 2026-10-30. Always failing: `01-always-fail` | 10 jobs per call, last build only | Page with `skip` | Cleanup candidates |
| **G9** Jobs using `@Library` or credentials | **Pass (limits).** Scripts of 01, 02, 03 and 04 contain no `@Library` and no `credentialsId` | Pipeline jobs that have run only | Add a sim that uses a library and a credential | Impact analysis before a secret rotation, without Git access |
| **G10** Weekly report | **Pass (limits).** See the weekly prompt below | See weekly | See weekly | See weekly |

### EKS agent scaling prompts

| Prompt | Results | Issues | Suggestion | Value provided by MCP |
| --- | --- | --- | --- | --- |
| **SC1** Builds waiting over 5 minutes | **Pass (limits), upgrade from N/A.** `TimeInQueueAction` gives `waitingDurationMillis` and `buildableDurationMillis` per build. Sampled builds: 0 ms | No fleet-wide query. Not run for 7 days | Loop over builds with `getJob builds[number]` then `getBuild` with the actions tree | Real queue waits, which the plan assumed were unavailable |
| **SC2** Pod start delay | **Pass (limits).** 03 vs 01 on `controller1`: 115.7 s vs 17.9 s (about +98 s). Duration minus `executingTimeMillis` gives about 104.6 s on `controller1` and 132.1 s on `folder-controller1` | Proxy only | Mark as "(proxy)" in reports | A pod provisioning estimate from Jenkins data alone |
| **SC3** Pod errors in the log | **Pass.** `06-bad-image` on `controller1`: 14 matches of `ErrImagePull`, `ImagePullBackOff` and "Still waiting to schedule task". The plan's log assumption is verified | OOMKilled not tested (`05` exists only on `controller3` and never ran) | Enable 05 on all controllers | Pinpoints image and scheduling problems without `kubectl` |
| **SC4** Peak concurrency by hour | **Not run.** No router tool | Confirmed N/A by the tool list | See Appendix A of the plan | None |
| **SC5** Executor capacity | **Pass (limits).** Executors 1/1/0/0/0 | Idle controllers show 0 because pods are ephemeral (finding 4) | Do not use for sizing | Instant executor count per controller |

### Security audit prompts

| Prompt | Results | Issues | Suggestion | Value provided by MCP |
| --- | --- | --- | --- | --- |
| **SE1** Plugin advisories | **N/A (confirmed).** No plugin tool. The `getStatus` admin monitor "Non-CAP Plugins Monitor" is active on all 5 controllers | No advisory data | Use the Plugin Manager | A hint that non-CAP plugins are installed |
| **SE2** Jobs using credential X | **Pass (limits).** Same as G9: none in the scanned scripts | Pipeline scripts only | Same as G9 | Same as G9 |
| **SE3** Risky patterns in 07 | **Pass.** Script shows `privileged: true`, a `hostPath` mount of `/var/run/docker.sock`, `alpine:latest`, and an echoed `curl ... \| sh` | Built-in node usage not available | Act on finding 6 | Static security review of Pipeline code through the router |
| **SE4** RBAC and admins | **N/A (confirmed).** `whoAmI` returns only `user-a` | No users or RBAC tool | Use `casc/cjoc/rbac.yaml` and the UI | None |
| **SE5** Unpinned libraries, `latest`, `curl \| sh` | **Pass (limits).** Only 07 uses `latest` and `curl \| sh`. 01 to 04 pin `alpine:3.20` and use no library | 05 and 06 were not scanned (06 uses an intentionally bad tag) | Scan all jobs with a loop | Supply-chain checks without cloning repos |

### Report prompts

| Prompt | Results | Issues | Suggestion | Value provided by MCP |
| --- | --- | --- | --- | --- |
| **Weekly report** | **Pass (limits).** Run from the data above. **Fleet:** all 4 controllers online on `2.580.2.38435`. **Failing:** 01-always-fail everywhere; 02-flaky fails on `controller1`; 06-bad-image does not finish (finding 3). **Pod errors:** `ErrImagePull`/`ImagePullBackOff` in 06. **Risky:** 07 on the 2 controllers where it ran. **Data gaps:** plugin advisories, plugin drift, RBAC, queue history, peak concurrency | History is thin (builds are 11 days old or new), so success rates are not meaningful yet | Rerun after a week of builds. Add `getFlakyFailures` once a test-reporting sim exists | A structured report with explicit data gaps from only MCP data |
| **Daily check** | **Pass (limits).** Verdict **[Warning]**: 06-bad-image running 13 min with no timeout; 01-always-fail failing on all 4 controllers; 02-flaky failing on `controller1`; no queue backlog | Needed several calls and one retry | Split into two runs if it times out | A fast daily triage |

### Write-tool tests (controller1, job `01-always-fail`)

| Prompt | Results | Issues | Suggestion | Value provided by MCP |
| --- | --- | --- | --- | --- |
| **W1** Trigger 01 on controller1 | **Pass.** Queue item 13, build #2, `FAILURE` in about 10 s | The first call timed out without triggering (finding 5) | Check `nextBuildNumber` before retrying | Starts a build and links it to the user |
| **W2** Trigger 04 with `PODS=2` | **Not run** (skipped by choice) | 04 is broken (finding 2) | Fix the `${n}` escape first | None |
| **W3** Rebuild build 1 | **Pass.** Queue item 15, build #3, `FAILURE` in 10.5 s | None | None | Re-runs a build with the same parameters |
| **W4** Rename build | **Pass.** Build #2 now has `displayName` `mcp-test` and description `router test` (verified with `getJob`) | None. This label stays on the build | Revert it in the UI if unwanted | Annotates builds from an agent session |
| **W5** Replay with a changed script | **Pass.** Queue item 17, build #4 ran the edited script. The log shows `... 401 Unauthorized (replayed via MCP)` | None | Treat replay like code execution and require approval | Tests a pipeline change without a commit |

## Suggested plan updates

1. Upgrade **SC1** from N/A to Partial (`TimeInQueueAction`) and mark the `queueItem`, `{0,N}` range and log-string assumptions as verified.
2. Add a note on `getBuildScm` throwing an NPE for inline pipelines, and on the unreliable `getStatus` cloud and executor fields.
3. Fix `04-queue-pressure` (`^${n}`) and `06-bad-image` (timeout) in `mcp-test-items.yaml`, then rerun G6, SC3 and W2.
4. Say that `07-risky-patterns` runs successfully on these clusters.
5. Add sims with a JUnit report and an SCM, so S11 to S13, `getTestResults` and `getFlakyFailures` return real data.

## Not verified

- Offline controllers (`controller2`, `hahs`, `plugable-storage`, `plugins-casc-uc`, `testnodegroup`) were not queried.
- `05-oomkilled` exists only on `controller3` and never ran, so OOMKilled detection is untested.
- The weekly and daily prompts were executed by hand from the collected tool data, not as a single agent run.
- Finding 3's explanation of the timeout is an assumption; only the observation (still running after 13 minutes) is verified.
