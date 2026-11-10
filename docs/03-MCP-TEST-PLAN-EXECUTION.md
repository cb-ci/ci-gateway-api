# CloudBees CI MCP Test & Evaluation Prompts

Use these prompts with your MCP client (Claude Code, Goose, etc.) connected to the CloudBees CI MCP Router.

---

### Prompt 1: Seed & Trigger Simulation Pipelines

Use this prompt to trigger the test pipelines in folder `mcp-test-pipeline` to establish build history across active controllers before running evaluations.

```text
Query the MCP router using listControllers to identify all online controllers (exclude offline or deprovisioned controllers like controller2). For each online controller (e.g., controller1, controller3, folder-controller1, folder-controller2, workshop):

1. Inspect the folder "mcp-test-pipeline" using getJobs to list available simulation jobs (e.g., 01-always-fail, 02-flaky, 03-slow-pod-start, 04-queue-pressure, 06-bad-image, 07-risky-patterns, and 05-oomkilled if present).
2. Report the jobs found per controller and ask for confirmation before triggering builds.
3. Upon confirmation, trigger each job using triggerBuild (verifying the current build status/queue to avoid duplicate runs on transient timeouts).
4. Monitor and summarize the initial execution results once triggered.
```

---

### Prompt 2: Execute Test Plan & Generate Results Report

Use this prompt to execute the prompts defined in `@docs/MCP-TEST-PLAN.md` and document the results into a timestamped markdown report matching the format of previous test runs.

```text
Execute the test plan defined in @docs/MCP-TEST-PLAN.md against the online controllers connected to the CloudBees CI MCP Router:

1. Scope & Prerequisites:
   - Run whoAmI to verify that the active user identity is authenticated (not anonymous).
   - Use listControllers to dynamically detect online controllers and scope all subsequent tool calls exclusively to online controllers to prevent timeouts.

2. Test Execution:
   - Execute the test prompts across sections:
     * Smoke tests (S1–S13)
     * General prompts (G1–G10)
     * EKS agent scaling prompts (SC1–SC5)
     * Security audit prompts (SE1–SE5)
     * Report prompts (Weekly report, Daily check)
     * Write-tool tests (W1–W4)
   - Evaluate each prompt and assign one of the standardized statuses:
     * Pass: Returned full, accurate data as expected.
     * Pass (limits): Returned valid data within documented router/tool boundaries or via a proxy.
     * Fail: Tool returned an error, exception (e.g., NPE), or incorrect data.
     * N/A: Confirmed not answerable by any router tool.

3. Reporting:
   - Format the results into a timestamped report file: docs/MCP-TEST-PLAN-RESULTS<YYYY-MM-DD_HHMM>.md.
   - Include:
     * Metadata header (run date/time, user, target scope, summary counts: Pass / Pass (limits) / Fail / N/A).
     * Key findings table (| # | Finding | Evidence | Suggestion |).
     * Detailed results tables by section with columns:
       | Prompt | Results | Issues | Suggestion | Value provided by MCP |
     * Explicit section on data gaps and tool limits.
```

---

### Prompt 3: Combined End-to-End Run (Seed + Test + Report)

```text
Perform an end-to-end evaluation of the CloudBees CI MCP Router:

1. Check router health (getRouterStatus) and user authentication (whoAmI).
2. Identify all active, online controllers using listControllers (skip deprovisioned/offline controllers such as controller2).
3. Check folder "mcp-test-pipeline" across the online controllers. If test pipelines have no recent builds, trigger them with triggerBuild after asking for confirmation.
4. Run each test prompt from @docs/MCP-TEST-PLAN.md (Smoke, General, Scaling, Security, Reports, Write tools).
5. Compile and save the complete evaluation report to docs/MCP-TEST-PLAN-RESULTS<YYYY-MM-DD_HHMM>.md, structured with:
   - Summary statistics (Pass, Pass with limits, Fail, N/A)
   - Key findings & discovered bugs/quirks
   - Prompt-by-prompt comparison table:
     | Prompt | Results | Issues | Suggestion | Value provided by MCP |
```
