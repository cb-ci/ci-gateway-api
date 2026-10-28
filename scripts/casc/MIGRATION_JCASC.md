# Migrating a JCasC controller to a CloudBees CasC bundle

Two scripts in this directory:

| Script | Purpose |
| --- | --- |
| `migrateJcasCController2CasCController.sh` | Exports the config of a Jenkins OSS controller (JCasC plugin) and builds a CloudBees CasC bundle (`bundle.yaml`, `jenkins.yaml`, `plugins.yaml`). Validates it on a test controller. |
| `runTestController.sh` | Starts a CloudBees CI controller in Docker with a CasC bundle mounted. Used by the migration script, also usable on its own. |

**Terms**

- **Source controller**: the old Jenkins OSS controller with the JCasC plugin.
- **Target controller**: the new CloudBees CI controller that loads the bundle.

## Prerequisites

- `curl`, `yq` (v4, the repo README asks for 4.30), `zip`
- `docker` (only when a test controller is started), `jq` (optional, used to read the validation result)
- A user and API token on the source controller that may call `/configuration-as-code/export` and `/scriptText` (administer permission)

## Configuration

The migration script reads `scripts/casc/.env` (git-ignored) and falls back to environment variables. Values in `.env` override the environment. Never commit tokens.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SRC_URL`, `SRC_USER`, `SRC_TOKEN` | required | Source controller URL, user, API token |
| `START_TEST_CONTROLLER` | `true` | Start a local test controller for the bundle check |
| `TEST_CI_VERSION` | `latest` | Image tag of `cloudbees/cloudbees-core-<type>` |
| `TEST_CI_TYPE` | `mm` | Image type (`mm` = managed controller) |
| `TEST_PORT` | `9080` | Host port mapped to 8080 |
| `TEST_JENKINS_HOME` | `<WORK_DIR>/test-controller/jenkins_home` | Jenkins home of the test controller |
| `TEST_CONTAINER_NAME` | `casc-migration-test` | Docker container name, used to find and stop it |
| `TEST_STARTUP_TIMEOUT` | `300` | Seconds to wait until the test controller answers |
| `KEEP_TEST_CONTROLLER` | `false` | Keep the test controller running after the script (same as `--keep-controller`) |
| `BUNDLE_ID` | `casc-controller` | `id` written to `bundle.yaml` |
| `WORK_DIR` | `${TMPDIR:-/tmp}/casc-migration-workdir` | Work dir, wiped at the start of every run |

Example `.env` (placeholders only):

```bash
SRC_URL=https://jenkins.example.com/jcasc-controller
SRC_USER=your-user
SRC_TOKEN=your-api-token
TEST_CI_VERSION=latest
```

## Usage

```bash
cd scripts/casc
cp .env.template .env      # then edit
./migrateJcasCController2CasCController.sh [options]
```

| Option | Meaning |
| --- | --- |
| `--keep-controller` | Leave the test controller running after the script. Default: it is stopped. Overrides `KEEP_TEST_CONTROLLER` from `.env` |
| `-y`, `--yes` | Do not ask before stopping an already running test controller and deleting its Jenkins home. Required when there is no terminal |
| `-h`, `--help` | Show the options |

Result in `$WORK_DIR`:

```
bundle/bundle.yaml    apiVersion "2", id, version, jcasc + plugins references
bundle/jenkins.yaml   exported and cleaned JCasC config
bundle/plugins.yaml   installed plugins (suspended ones removed)
bundle.zip            zipped bundle, as sent to the validation endpoint
plugins-export.txt    raw output of the plugin export
validation.json       response of the validate call (only when the validation block is enabled)
test-bundle/          copy of bundle/ without Operations Center settings, mounted into the test controller
test-bundle.zip       zip of test-bundle/
test-controller/      run.log, tmp.log (controller log), jenkins_home/
```

## What the migration script does

| Step | Action |
| --- | --- |
| 0 | Wipe and recreate `WORK_DIR`; copy the helper scripts and write a helper `.env` pointing at the work dir |
| 1 | `POST <SRC_URL>/configuration-as-code/export` writes `jenkins.yaml` |
| 2 | Run an inline groovy script via `<SRC_URL>/scriptText`; it prints `- id: <plugin>` per installed plugin |
| 3 | Parse the output into `plugins.yaml` (`plugins:` list, de-duplicated) |
| 4/5 | Run `scripts/00-indent2Yaml.sh`, `01-jenkinsYamlClean.sh` (removes the paths listed in `transform.yaml`), `02-pluginsRemoveSuspended.sh` |
| 6/7 | Write `bundle.yaml` directly as `apiVersion: "2"` |
| 8 | Check the YAML with `yq`, zip the bundle, start the test controller (if needed), validate |
| 9 | Not automated. The script prints how to apply the bundle |

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant M as migrateJcasCController2CasCController.sh
    participant H as helper scripts (00, 01, 02)
    participant S as Source controller (Jenkins OSS + JCasC)
    participant T as Test controller (see next diagram)

    U->>M: run (config from .env)
    M->>M: wipe and recreate WORK_DIR
    M->>S: POST /configuration-as-code/export
    S-->>M: jenkins.yaml
    M->>S: POST /scriptText (inline groovy)
    S-->>M: list of "- id: plugin"
    M->>M: build plugins.yaml
    M->>H: indent fix, clean jenkins.yaml, remove suspended plugins
    H-->>M: bundle files updated in place
    M->>M: write bundle.yaml (apiVersion 2), yq syntax check, zip
    M->>T: start, wait, validate
    T-->>M: validation result
    M-->>U: bundle ready, apply manually
```

## Test controller and validation

If `START_TEST_CONTROLLER=true` (the default), the script starts a throwaway controller with `runTestController.sh`.

**Before the work dir is wiped**, the script checks for a running container named `TEST_CONTAINER_NAME`, for example one kept alive by an earlier `--keep-controller` run. If it finds one, it prints the container's Jenkins home and asks `Stop it and delete its Jenkins home for a fresh start? [y/N]`.

- `n` (or Enter): the script aborts and changes nothing.
- `y`, or `--yes`: it stops the container and deletes the Jenkins home. It deletes only a home that lies under `WORK_DIR` or equals `TEST_JENKINS_HOME`. Any other path is left alone with a warning.
- No terminal and no `--yes`: the script exits with an error.

**Operations Center-free copy.** The test controller has no Operations Center, so the script copies `bundle/` to `test-bundle/` and runs `scripts/001-jenkinsYamlDisableOC.sh` on the copy. That replaces `securityRealm` with a local `admin` realm (from `patches/jenkins_securityrealm.yaml`), removes `authorizationStrategy` and removes the OC agent cloud entry. The real `bundle/` keeps its OC settings. The test controller mounts `test-bundle/`, and the port is bound to `127.0.0.1` only.

Then the script:

1. Waits for the named container, and fails early if `runTestController.sh` exits first (the last 20 lines of `run.log` are printed).
2. Waits until `<url>/login` answers 200, 401 or 403, up to `TEST_STARTUP_TIMEOUT` seconds.
3. Greps the controller log for bundle errors (`SEVERE` lines mentioning casc/bundle, or "Failed to load/apply ... bundle"). The patterns are a guess at the log wording (*unverified*).
4. Validation call: `POST /casc-bundle-mgnt/casc-bundle-validate` with `test-bundle.zip` (*unverified* on a standalone controller). **This block is currently commented out in the script.** When enabled, it logs in as `admin` with `TEST_ADMIN_PASSWORD`. The line that sets that random password is also commented out, so the admin password is the placeholder from the patch file until you re-enable it.
5. On exit (EXIT trap, including failure): stops the container, or with `--keep-controller` leaves it running and prints the URL and `docker stop <name>`.

```mermaid
sequenceDiagram
    autonumber
    participant M as migrate script
    participant R as runTestController.sh
    participant D as Docker
    participant C as Test controller (container)

    M->>R: start in background (-v -t -j -c -p -n)
    R->>D: docker info
    R->>R: mkdir jenkins_home, resolve absolute paths
    R->>D: docker run --rm --name casc-migration-test (volumes: jenkins_home, bundle)
    D->>C: start, load bundle from /tmp/casc-bundle
    loop until container exists (max 120s)
        M->>D: docker ps --filter name=...
        alt launcher exited early
            M-->>M: print run.log tail and exit 1
        end
    end
    loop until /login answers (max TEST_STARTUP_TIMEOUT)
        M->>C: GET /login
    end
    M->>M: grep tmp.log for bundle errors
    M->>C: POST /casc-bundle-mgnt/casc-bundle-validate (bundle.zip)
    C-->>M: validation result
    M->>D: docker stop (EXIT trap)
    D->>C: stop and remove (--rm)
```

## runTestController.sh

Starts `cloudbees/cloudbees-core-<type>:<version>` in the foreground and writes the log to `tmp.log` in the current directory.

| Option | Default | Meaning |
| --- | --- | --- |
| `-v, --version` | `latest` | Image tag |
| `-t, --type` | `mm` | Image type |
| `-j, --jenkins-home PATH` | `$PWD/jenkins_home-controller-base` | Mounted at `/var/jenkins_home` (created if missing) |
| `-c, --casc-bundle PATH` | `$PWD/controller-base` | Mounted at `/tmp/casc-bundle`; must exist |
| `-p, --port MAPPING` | `9080:8080` | Docker port mapping |
| `-n, --name NAME` | docker generated | Container name |

Relative paths for `-j` and `-c` are converted to absolute paths, because Docker would otherwise read them as volume names.

Notes:

- The controller loads the bundle through `-Dcore.casc.config.bundle=/tmp/casc-bundle`. HA is disabled (`-Dcom.cloudbees.jenkins.ha=false`) and the update-center signature check is off (`noSignatureCheck=true`), so use it for tests only.
- The container uses `--rm`, so it is removed when stopped.
- The first run pulls the image, which can take a while.

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant R as runTestController.sh
    participant D as Docker
    participant C as Container

    U->>R: ./runTestController.sh -c bundle-dir [options]
    R->>R: parse options
    R->>D: docker info
    alt Docker not running
        R-->>U: error, exit 1
    end
    R->>R: mkdir -p jenkins_home, chmod 775
    alt bundle dir missing
        R-->>U: error, exit 1
    end
    R->>R: convert -j and -c to absolute paths
    R->>D: docker run --rm (-e JAVA_OPTS, -p, -v home, -v bundle)
    D->>C: start CloudBees CI
    C-->>R: log output
    R->>R: tee tmp.log
    Note over R,C: runs in the foreground until the container stops
```

## Known limitations and things to review

- **Apply is manual.** The script only builds and validates. Copy the bundle to the target's bundle location or upload it via the UI.
- **Review `jenkins.yaml` before use.** The JCasC export can contain secret references or environment-specific values. Only the paths in `transform.yaml` are removed.
- **Plugin list is names only.** Versions are not pinned in `plugins.yaml`.
- **Unverified assumptions:** the validate endpoint on a standalone controller, the log patterns, and the admin login. Check them on the first run and adjust.
- **The test controller loads the OC-free copy**, not your real bundle. Startup success shows the rest of the bundle loads, but it says nothing about the OC settings.
- **Startup failures seen so far:** an empty `advisor: {}` section (now removed through `transform.yaml`) and user properties like `apiToken` in the shared security realm patch (rejected by newer controllers; the test copy of the patch drops them when the `yq` line in the script is active). Other empty `{}` sections may be rejected the same way.
- **Cleanup.** The work dir is deleted at the start of each run, only if it is empty or carries the `.casc-migration-workdir` marker. On Linux, root-owned files from the container's jenkins_home may block the deletion.
- **A running container** named `casc-migration-test` is handled by the prompt described above. A custom `TEST_JENKINS_HOME` outside `WORK_DIR` is only deleted together with a running container that uses it, so a stale one from a stopped container stays. If `docker run` still fails with a name conflict, run `docker rm -f casc-migration-test`.
