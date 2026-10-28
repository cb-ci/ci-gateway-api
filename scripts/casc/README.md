# CasC bundle tooling

Helper scripts for cleaning up and transforming Jenkins Configuration as Code (CasC) bundles exported from CloudBees CI controllers, so they can be reused (for example for local development or a new controller setup).

## Tools

The scripts require yq version 4.30

```
yq --version
yq (https://github.com/mikefarah/yq/) version v4.30.5
```

## Setup

Copy `scripts/.env.template` to `scripts/.env` and adjust it. Every script sources `scripts/.env`.

| Variable | Purpose |
| --- | --- |
| `CASC_BUNDLES_PATH` | Absolute path to the directory containing the exported bundles |
| `BASE_PATH` | Base path used by the plugin scripts to locate `plugins.yaml` files |
| `TRANSFORM_FILE` | Path to `transform.yaml` |
| `JENKINS_YAML` | File name of the Jenkins CasC file (default `jenkins.yaml`) |
| `PLUGINS_YAML` | File name of the plugins file (default `plugins.yaml`) |
| `VAR_PREFIX` | Prefix for secret references (default `readFile:/var/run/secrets/controller/`) |

Note: most scripts modify files in place under `CASC_BUNDLES_PATH`. Work on a copy or a clean git checkout.

## Layout

```
casc/
├── patch.sh              # standalone one-off cleanup of a single jenkins.yaml
├── transform.yaml        # list of YAML paths removed by 01-jenkinsYamlClean.sh
├── patches/              # YAML snippets used by the scripts
│   ├── jenkins_securityrealm.yaml
│   └── jenkins_cloud_amazonEC2.yaml
└── scripts/
```

## Files in the casc directory

- `patch.sh [jenkins.yaml]` - Backs up the given file to `<file>.bak`, deletes a fixed set of keys (license, update center, operations center root action, credentials and similar), writes the result to `patched-jenkins.yaml` and prints a diff against the original. Standalone, does not use `.env`.
- `transform.yaml` - List of `op: remove` entries with a `path` each (for example `unclassified.location`, `tool.go`). It holds the keys that are removed by `01-jenkinsYamlClean.sh`. Commented-out entries are for local development without an operations center.
- `patches/jenkins_securityrealm.yaml` - Local security realm with an `admin` user. It replaces `jenkins.securityRealm` in `001-jenkinsYamlDisableOC.sh`. The password is a placeholder (`XXX`), change it.
- `patches/jenkins_cloud_amazonEC2.yaml` - Placeholder values (`TODO-...`) for the required fields of the Amazon EC2 cloud. See `scripts/YQ_README.md` for how it is merged.

## Scripts

The numeric prefix indicates the order of the workflow. Scripts without a number are utilities.

### Preparation

- `renameCasCDirs.sh` - Renames every directory in the current directory ending with `-core-casc-export-jenkins` by removing that suffix. Run it inside the directory with the exports.
- `00-indent2Yaml.sh` - Re-formats every `*.yaml` below `CASC_BUNDLES_PATH` with a 2 space indent. CasC exports from CloudBees CI use a different indent.

### Jenkins configuration (`jenkins.yaml`)

- `01-jenkinsYamlClean.sh` - For every `jenkins.yaml` below `CASC_BUNDLES_PATH`, deletes all paths listed with `op: remove` in `transform.yaml` (relative to the script directory, so run it from `scripts/`).
- `001-jenkinsYamlDisableOC.sh` - Decouples controllers from the operations center: sets a local security realm (from `patches/jenkins_securityrealm.yaml`), removes the `operationsCenterAgentProvisioningService` cloud and deletes `jenkins.authorizationStrategy`. Bundles in a directory named `Operations-center` are skipped.
- `001-jenkinsYamlEnableOC.sh` - Reverse of the above: sets `securityRealm: "operationsCenter"`, `authorizationStrategy: "cloudBeesRoleBasedAccessControl"` and adds the `operationsCenterAgentProvisioningService` cloud. `Operations-center` is skipped.
- `002-jenkinsYamlSplit.sh` - Splits `${CASC_BUNDLES_PATH}/${JENKINS_YAML}` into one file per root key and second-level key, written to `${CASC_BUNDLES_PATH}/splitdir/<root>.<key>.yaml`. This makes large files easier to review and diff.
- `002-jenkinsYamlMerge.sh` - Merges the snippets in `splitdir/` back into `jenkins.rebuilt.yaml` and writes `jenkins.rebuilt.resorted.yaml` with the root keys in a fixed order (`jenkins`, `beekeeper`, `support`, `globalCredentialsConfiguration`, `appearance`, `security`, `unclassified`, `tool`). The output is written to the current directory.
- `03-jenkinsYamlUpdateCredentials.sh` - Replaces credential values in `${CASC_BUNDLES_PATH}/${JENKINS_YAML}` with variable placeholders of the form `${<ID>-<FIELD>}`, where `<ID>` is the upper-cased credential id. Covers `usernamePassword` (`USERNAME`, `PASSWORD`), `string`/`secretText` (`SECRET`), `basicSSHUserPrivateKey` (`USERNAME`, `PRIVATE_KEY`) and `aws` (`ACCESS_KEY`, `SECRET_KEY`). Secret file handling is commented out. Supply the actual values through environment variables or secret files (see `VAR_PREFIX`). Note: this edits a single file in place.

### Plugins (`plugins.yaml`)

- `02-pluginsRemoveSuspended.sh` - Removes suspended or deprecated plugins (for example `blueocean*`, `windows-slaves`, `build-flow-plugin`) from every `plugins.yaml` below `CASC_BUNDLES_PATH`. The lists are hardcoded at the top of the script.
- `004-pluginsGetAllPluginIDs.sh` - Concatenates all `plugins.yaml` files below `BASE_PATH` into a sorted, de-duplicated `plugins-all.yaml` in the current directory.
- `004-pluginsGetCommonPluginIDs.sh` - Computes the plugin IDs present in every `plugins.yaml` below `BASE_PATH` and writes them (without versions) to `plugins-common.yaml`. Use it to find candidates for a shared parent bundle.
- `004-pluginsGetPluginsUniqOnlyInOnefile.sh [plugins-common.yaml]` - For each `plugins.yaml` below `BASE_PATH`, rewrites it to contain only the plugins that are not in the common file, and prints a summary. This overwrites the controller files, so run `004-pluginsGetCommonPluginIDs.sh` first and keep a backup.
- `004-pluginsMergeParentPlugins.sh` - Merges `plugins.yaml` files of a child bundle directory (`../../controller-child`) with the parent (`../../controller-base`) into `./output`, de-duplicated and sorted by plugin id. Also copies `bundle.yaml`, `jenkins.yaml`, `rbac.yaml` and `items.yaml` from the base and comments out the `parent: "base-bundle"` line in `bundle.yaml` for local development. The directories are hardcoded in the script. Known issue: the last loop uses `$file_b` instead of `$file_a`, so base-only plugin files are not copied correctly.

### Other

- `simpleTest.sh` - Scratch script that deletes `jenkins.agentProtocols` from a hardcoded file with yq. Only useful to test a yq expression.
- `YQ_README.md` - yq snippets: running yq with docker, applying `patch` operations from `transform.yaml`, and merging the EC2 cloud patch.

## Suggested workflow

1. `renameCasCDirs.sh` and `00-indent2Yaml.sh` to normalize the export.
2. `01-jenkinsYamlClean.sh` to remove unsupported or environment-specific keys.
3. `001-jenkinsYamlDisableOC.sh` for local development without an operations center (or `001-jenkinsYamlEnableOC.sh` to restore).
4. `02-pluginsRemoveSuspended.sh`, then the `004-plugins*` scripts to extract common plugins into a parent bundle.
5. `03-jenkinsYamlUpdateCredentials.sh` to replace credential values with placeholders.
