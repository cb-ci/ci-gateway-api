#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"
#JENKINS_YAML="${CASC_BUNDLES_PATH/credentials.yaml}"
JENKINS_YAML="${CASC_BUNDLES_PATH}/$JENKINS_YAML"

## When using ENV_VARS
#VAR_PREFIX=""
## When reading secrets from file
#VAR_PREFIX='readFile:/var/run/secrets/controller/'


# usernamePassword → ${ID-USERNAME} / ${ID-PASSWORD}
yq -i '
(.credentials.system.domainCredentials[].credentials[]
 | select(has("usernamePassword")).usernamePassword) |=
 ( . as $c
   | ($c.id | upcase | sub("[^A-Z0-9]+"; "-")) as $ID
   | .username = "${" + $ID + "-USERNAME}"
   | .password = "${" + $ID + "-PASSWORD}"
 )
' "$JENKINS_YAML"

# string (Secret text) → ${ID-SECRET}
yq -i '
(.credentials.system.domainCredentials[].credentials[]
 | select(has("string")).string) |=
 ( . as $c
   | ($c.id | upcase | sub("[^A-Z0-9]+"; "-")) as $ID
   | .secret = "${" + $ID + "-SECRET}"
 )
' "$JENKINS_YAML"

# secretText → ${ID-SECRET}
yq -i '
(.credentials.system.domainCredentials[].credentials[]
 | select(has("secretText")).secretText) |=
 ( . as $c
   | ($c.id | upcase | sub("[^A-Z0-9]+"; "-")) as $ID
   | .secret = "${" + $ID + "-SECRET}"
 )
' "$JENKINS_YAML"

# basicSSHUserPrivateKey.username → ${ID-USERNAME}
yq -i '
(.credentials.system.domainCredentials[].credentials[]
 | select(has("basicSSHUserPrivateKey")).basicSSHUserPrivateKey) |=
 ( . as $c
   | ($c.id | upcase | sub("[^A-Z0-9]+"; "-")) as $ID
   | .username = "${" + $ID + "-USERNAME}"
 )
' "$JENKINS_YAML"

# basicSSHUserPrivateKey.privateKey (only when directEntry exists) → ${ID-PRIVATE_KEY}
yq -i '
(.credentials.system.domainCredentials[].credentials[]
 | select(has("basicSSHUserPrivateKey")
          and (.basicSSHUserPrivateKey.privateKeySource.directEntry.privateKey? != null))
 | .basicSSHUserPrivateKey) |=
( . as $c
  | ($c.id | upcase | sub("[^A-Z0-9]+"; "-")) as $ID
  | .privateKeySource.directEntry.privateKey = "${" + $ID + "-PRIVATE_KEY}"
)
' "$JENKINS_YAML"

# aws → ${ID-ACCESS_KEY} / ${ID-SECRET_KEY}
yq -i '
(.credentials.system.domainCredentials[].credentials[]
 | select(has("aws")).aws) |=
 ( . as $c
   | ($c.id | upcase | sub("[^A-Z0-9]+"; "-")) as $ID
   | .accessKey = "${" + $ID + "-ACCESS_KEY}"
   | .secretKey = "${" + $ID + "-SECRET_KEY}"
 )
' "$JENKINS_YAML"

# file (Secret file) → ${ID-SECRET_BYTES}
#yq -i '
#(.credentials.system.domainCredentials[].credentials[]
# | select(has("file")).file) |=
# ( . as $c
#   | ($c.id | upcase | sub("[^A]()
