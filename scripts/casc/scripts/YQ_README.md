# Docker run yq

> docker run --rm -it -v "${PWD}":/workdir mikefarah/yq:4.47.1 sh

# Loop through each replace operation

```
INDEX=0
yq -e '.[] | select(.op == "patch") | [.path, .patchfile] | @tsv' "$TRANSFORM_FILE" | \
while IFS=$'\t' read -r path patchfile; do
   PATCH_PATH="${path/}"   Strip leading slash
   echo "[$((++INDEX))] ❌ Patch with: .$PATCH_PATH"
   echo "Patchfile: $patchfile"
   echo $path
   yq -i ".\"$path\" = load(\"$patchfile\")" $OUTPUT_FILE
done
```

# fix EC2 plugin missing fields, merge missing fields

```
yq -i ".jenkins.clouds = load(\"../patches/jenkins_cloud_amazonEC2.yaml\")" $OUTPUT_FILE
yq -i ".jenkins.clouds[0].amazonEC2 *= load(\"../patches/jenkins_cloud_amazonEC2.yaml\").jenkins.clouds[0].amazonEC2" $OUTPUT_FILE
yq -i  ".jenkins.clouds[0].amazonEC2 *= load(\"$SCRIPT_DIR/../patches/jenkins_cloud_amazonEC2.yaml\").jenkins.clouds[0].amazonEC2" $OUTPUT_FILE

#EC2 requires new fields in the latest version
randomid=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
yq -i '(.jenkins.clouds[] | select(has("amazonEC2"))).amazonEC2.credentialsId = "my-ec2-credentialID-'$randomid'"' $OUTPUT_FILE

```

# EC2 does not allow the name field anymore

## add name field

```
 yq -i '(.jenkins.clouds[] | select(has("amazonEC2"))).amazonEC2.name = "my-ec2-cloud"' $OUTPUT_FILE 

```

## rename cloudName to name

```
yq  -i '(.[] | select(.amazonEC2.cloudName) | .amazonEC2.name) = .amazonEC2.cloudName | del(.[] | .amazonEC2.cloudName)' $OUTPUT_FILE
```

## remove name field

```
yq -i '(.jenkins.clouds[] | select(has("amazonEC2"))).amazonEC2 |= del(.cloudName)' "$OUTPUT_FILE"
```
