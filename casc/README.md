# Bundle validation

SA=${SA:-service-account:token}
CJOC=${CJOC:-<http://localhost:8080/cjoc}>
CONTROLLER=${CONTROLLER:-http://localhost:8080/controller1}
BUNDLE_ID=${BUNDLE_ID:-main/controller-base}

## Validates raw bundles over HTTP before adding them to the operations center

* POST /casc-bundle/pre-validate-bundle

NOTE: requires inheritance

It accepts a .zip file containing child and parent bundles, calculates the effective bundle, and performs structural validation
Validates raw bundles before adding them to the operations center. The bundle must be a .zip file.

The expected input is a .zip file that contains all child and parent bundles that have changes. The output is the effective bundle in .zip format. The following is an example of the file structure of the .zip file:

branch-1

* folder1
  * bundle-1
  * bundle-2
* folder2
  * bundle-3
* bundle-4
branch-2
* bundle-5

Inconsistencies found within a bundle, such as referencing a missing file, return an error, and the effective bundle is not generated.

```bash
curl -v -H 'Accept: application/json' -H 'Content-Type: application/zip;charset=utf-8' --user "$SA" --data-binary "@controller-base.zip" -XPOST "$CJOC/casc-bundle/pre-validate-bundle" 
```

## Retrieves the validation logs for effective bundles

* GET /casc-bundle/effective-bundle-validation-log

The output can be filtered using the controller parameter, which accepts a regular expression to target specific controllers
NOTE: This only works for bundles manages by CJOC, Casc Bundle service validations are not available

```bash
curl --user "$SA" -XGET "$CJOC/casc-bundle/effective-bundle-validation-log?controller=controller-.*1" | jq
```

```json
{
  "validation-log": [
    {
      "controller": "controller1",
      "records": [
        {
          "bundle": "main/controller-base",
          "assigned": true,
          "version": "2",
          "errors": 0,
          "warnings": 0,
          "info": 2,
          "messages": [
            "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
            "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
          ],
          "folder": "20260823_00001",
          "date": "August 23, 2026, 1:42 PM UTC"
        },
        {
          "bundle": "main/controller-base",
          "assigned": false,
          "version": "5",
          "errors": 0,
          "warnings": 0,
          "info": 2,
          "messages": [
            "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
            "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
          ],
          "folder": "20260821_00006",
          "date": "August 21, 2026, 5:57 PM UTC"
        },
        {
          "bundle": "main/controller-base",
          "assigned": false,
          "version": "4",
          "errors": 0,
          "warnings": 0,
          "info": 2,
          "messages": [
            "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
            "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
          ],
          "folder": "20260821_00005",
          "date": "August 21, 2026, 5:57 PM UTC"
        },
        {
          "bundle": "main/controller-base",
          "assigned": false,
          "version": "3",
          "errors": 0,
          "warnings": 0,
          "info": 2,
          "messages": [
            "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
            "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
          ],
          "folder": "20260821_00003",
          "date": "August 21, 2026, 12:38 PM UTC"
        },
        {
          "bundle": "main/controller-base",
          "assigned": false,
          "version": "1",
          "errors": 0,
          "warnings": 0,
          "info": 2,
          "messages": [
            "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
            "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
          ],
          "folder": "20260821_00001",
          "date": "August 21, 2026, 8:41 AM UTC"
        }
      ]
    }
  ]
}
```

## Retrieves the full validation log for all raw bundles

GET /casc-bundle/raw-bundle-validation-log

Specifying the optional controller=true query parameter enriches the response with controller-specific effective validation logs

```bash
curl --user "$SA" -XGET "$CJOC/casc-bundle/raw-bundle-validation-log?bundle=$BUNDLE_ID&controller=true" | jq
```

```json
{
  "validation-log": [
    {
      "bundle-id": "main/controller-base",
      "records": [
        {
          "version": "2",
          "errors": 0,
          "warnings": 0,
          "info": 11,
          "messages": [
            "INFO - [STRUCTURE] - [FileSystemBundleValidator] All files indicated in the bundle exist and have the correct type.",
            "INFO - [CONTVAL] - [ContentBundleValidator] All files specified in the bundle exist and no unreferenced files indicated.",
            "INFO - [SCHEMA] - All YAML files validated correctly against their corresponding schemas",
            "INFO - [STRUCTURE] - [ParentValidator] Inheritance validation passed.",
            "INFO - [DESCVAL] - [DescriptorValidator] All files referenced in the descriptor are folders or yaml files.",
            "INFO - [VERSIONVAL] - [VersionValidator] Version correctly indicated in bundle.yaml.",
            "INFO - [APIVAL] - [ApiValidator] apiVersion correctly indicated in bundle.yaml.",
            "INFO - [JCASCSTRATEGY] - [JcascMergeStrategyValidator] No (optional) jcascMergeStrategy defined in the bundle.",
            "INFO - [ITEMSTRATEGY] - [ItemRemoveStrategyValidator] No (optional) itemRemoveStrategy defined in the bundle.",
            "INFO - [CATALOGVAL] - [MultipleCatalogFilesValidator] No catalog validation needed.",
            "INFO - [CATALOGVAL] - [AllowBeekeeperExceptionValidator] No catalog defined in the bundle."
          ],
          "folder": "20260823_00001",
          "date": "August 23, 2026, 1:42 PM UTC"
        },
        {
          "version": "5",
          "errors": 0,
          "warnings": 0,
          "info": 11,
          "messages": [
            "INFO - [STRUCTURE] - [FileSystemBundleValidator] All files indicated in the bundle exist and have the correct type.",
            "INFO - [CONTVAL] - [ContentBundleValidator] All files specified in the bundle exist and no unreferenced files indicated.",
            "INFO - [SCHEMA] - All YAML files validated correctly against their corresponding schemas",
            "INFO - [STRUCTURE] - [ParentValidator] Inheritance validation passed.",
            "INFO - [DESCVAL] - [DescriptorValidator] All files referenced in the descriptor are folders or yaml files.",
            "INFO - [VERSIONVAL] - [VersionValidator] Version correctly indicated in bundle.yaml.",
            "INFO - [APIVAL] - [ApiValidator] apiVersion correctly indicated in bundle.yaml.",
            "INFO - [JCASCSTRATEGY] - [JcascMergeStrategyValidator] No (optional) jcascMergeStrategy defined in the bundle.",
            "INFO - [ITEMSTRATEGY] - [ItemRemoveStrategyValidator] No (optional) itemRemoveStrategy defined in the bundle.",
            "INFO - [CATALOGVAL] - [MultipleCatalogFilesValidator] No catalog validation needed.",
            "INFO - [CATALOGVAL] - [AllowBeekeeperExceptionValidator] No catalog defined in the bundle."
          ],
          "folder": "20260821_00004",
          "date": "August 21, 2026, 5:57 PM UTC"
        },
       ......
      ],
      "controllers": [
        {
          "controller": "controller1",
          "records": [
            {
              "bundle": "main/controller-base",
              "assigned": true,
              "version": "2",
              "errors": 0,
              "warnings": 0,
              "info": 2,
              "messages": [
                "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
                "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
              ],
              "folder": "20260823_00001",
              "date": "August 23, 2026, 1:42 PM UTC"
            }
          ]
        },
        {
          "controller": "test",
          "records": [
            {
              "bundle": "main/controller-base",
              "assigned": true,
              "version": "2",
              "errors": 0,
              "warnings": 0,
              "info": 2,
              "messages": [
                "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
                "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
              ],
              "folder": "20260823_00001",
              "date": "August 23, 2026, 1:42 PM UTC"
            }
          ]
        }
      ]
    }
  ]
}
```

## Validates a bundle that has already been uploaded and stored within the operations center's local filesystem

* POST /casc-bundle/validate-uploaded-bundle

```bash
curl --user "$SA" -XPOST "$CJOC/casc-bundle/validate-uploaded-bundle?bundleId=$BUNDLE_ID"| jq
```

```json
{
  "valid": true,
  "structureValidations": [
    {
      "level": "INFO",
      "validationCode": "BUNDLE_STRUCTURE",
      "message": "[STRUCTURE] - [FileSystemBundleValidator] All files indicated in the bundle exist and have the correct type."
    },
    {
      "level": "INFO",
      "validationCode": "BUNDLE_CONTENT",
      "message": "[CONTVAL] - [ContentBundleValidator] All files specified in the bundle exist and no unreferenced files indicated."
    },
    {
      "level": "INFO",
      "validationCode": "SCHEMA",
      "message": "[SCHEMA] - All YAML files validated correctly against their corresponding schemas"
    },
    {
      "level": "INFO",
      "validationCode": "BUNDLE_STRUCTURE",
      "message": "[STRUCTURE] - [ParentValidator] Inheritance validation passed."
    },
    {
      "level": "INFO",
      "validationCode": "DESCRIPTOR",
      "message": "[DESCVAL] - [DescriptorValidator] All files referenced in the descriptor are folders or yaml files."
    },
    {
      "level": "INFO",
      "validationCode": "BUNDLE_VERSION",
      "message": "[VERSIONVAL] - [VersionValidator] Version correctly indicated in bundle.yaml."
    },
    {
      "level": "INFO",
      "validationCode": "BUNDLE_API",
      "message": "[APIVAL] - [ApiValidator] apiVersion correctly indicated in bundle.yaml."
    },
    {
      "level": "INFO",
      "validationCode": "BUNDLE_JCASC_STRATEGY",
      "message": "[JCASCSTRATEGY] - [JcascMergeStrategyValidator] No (optional) jcascMergeStrategy defined in the bundle."
    },
    {
      "level": "INFO",
      "validationCode": "BUNDLE_ITEM_STRATEGY",
      "message": "[ITEMSTRATEGY] - [ItemRemoveStrategyValidator] No (optional) itemRemoveStrategy defined in the bundle."
    },
    {
      "level": "INFO",
      "validationCode": "PLUGIN_CATALOG",
      "message": "[CATALOGVAL] - [MultipleCatalogFilesValidator] No catalog validation needed."
    },
    {
      "level": "INFO",
      "validationCode": "PLUGIN_CATALOG",
      "message": "[CATALOGVAL] - [AllowBeekeeperExceptionValidator] No catalog defined in the bundle."
    }
  ],
  "errorCount": 0,
  "controllerValidations": [
    {
      "controller": "test",
      "controllerStatus": "ONLINE",
      "validations": [
        {
          "level": "INFO",
          "validationCode": "JCASC_CONFIGURATION",
          "message": "[JCASC] - [JCasCValidator] All configurations validated successfully."
        },
        {
          "level": "INFO",
          "validationCode": "PLUGIN_AVAILABLE",
          "message": "[PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
        }
      ]
    },
    {
      "controller": "controller1",
      "controllerStatus": "ONLINE",
      "validations": [
        {
          "level": "INFO",
          "validationCode": "JCASC_CONFIGURATION",
          "message": "[JCASC] - [JCasCValidator] All configurations validated successfully."
        },
        {
          "level": "INFO",
          "validationCode": "PLUGIN_AVAILABLE",
          "message": "[PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
        }
      ]
    }
  ]
}
```

## Performs a complete validation (both structural and runtime validations) against a running CloudBees CI instance (Operations Center or Controller)

* POST /casc-bundle-mgnt/casc-bundle-validate

It requires the CloudBees CasC Client plugin to be installed

```bash
# Create a bundle file
zip -j controller-base.zip controller-base/*
# Validate the bundle file
curl --user "$SA" --data-binary "@controller-base.zip" -H "Content-Type: application/zip;charset=utf-8" -XPOST "$CONTROLLER/casc-bundle-mgnt/casc-bundle-validate" | jq
```

```json
{
  "valid": true,
  "validation-messages": [
    "INFO - [STRUCTURE] - [FileSystemBundleValidator] All files indicated in the bundle exist and have the correct type.",
    "INFO - [DESCVAL] - [DescriptorValidator] All files referenced in the descriptor are folders or yaml files.",
    "INFO - [VERSIONVAL] - [VersionValidator] Version correctly indicated in bundle.yaml.",
    "INFO - [APIVAL] - [ApiValidator] apiVersion correctly indicated in bundle.yaml.",
    "INFO - [JCASCSTRATEGY] - [JcascMergeStrategyValidator] No (optional) jcascMergeStrategy defined in the bundle.",
    "INFO - [ITEMSTRATEGY] - [ItemRemoveStrategyValidator] No (optional) itemRemoveStrategy defined in the bundle.",
    "INFO - [CONTVAL] - [ContentBundleValidator] All files specified in the bundle exist and no unreferenced files indicated.",
    "INFO - [SCHEMA] - All YAML files validated correctly against their corresponding schemas",
    "INFO - [CATALOGVAL] - [PluginCatalogInOCValidator] No plugin catalog specified.",
    "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog.",
    "INFO - [CATALOGVAL] - [MultipleCatalogFilesValidator] No catalog validation needed.",
    "INFO - [CATALOGVAL] - [AllowBeekeeperExceptionValidator] No catalog defined in the bundle.",
    "INFO - [JCASC] - [JCasCValidator] All configurations validated successfully.",
    "INFO - [PLUGINVAL] - [PluginsToInstallValidator] All plugins are present in the envelope or in the plugin catalog."
  ]
}
```

## Json Results Comparsion

The following table highlights the differences in the JSON responses returned by the various CasC bundle validation endpoints:

| Endpoint | Description | JSON Structure / Key Characteristics |
| :--- | :--- | :--- |
| `GET /casc-bundle/effective-bundle-validation-log` | Validation logs for effective bundles currently assigned to controllers. | Returns a `validation-log` list grouped by **`controller`**. Each entry contains a `records` array with historical data (`bundle`, `version`, `errors`, `messages`, etc.). |
| `GET /casc-bundle/raw-bundle-validation-log` | Full validation history for raw bundles (optionally enriched with controller logs). | Returns a `validation-log` list grouped by **`bundle-id`**. Each entry contains overall bundle `records`, and an optional `controllers` array detailing effective validations. |
| `POST /casc-bundle/validate-uploaded-bundle` | Validates an existing bundle stored in the operations center against assigned controllers. | Returns a detailed object separating validations into **`structureValidations`** and **`controllerValidations`** (showing controller statuses), along with an `errorCount` and a `valid` boolean. |
| `POST /casc-bundle-mgnt/casc-bundle-validate` | Immediate structural and runtime validation of an uploaded `.zip` payload. | Returns a simpler flat structure with a **`valid`** boolean and a unified **`validation-messages`** array of strings (combining structural, API, and plugin info). |
