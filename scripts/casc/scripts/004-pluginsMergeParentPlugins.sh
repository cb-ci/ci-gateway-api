#!/bin/bash

DIR_B="../../controller-base"
DIR_A="../../controller-child"
DIR_MERGED="./output"



mkdir -p "$DIR_MERGED"


for file_a in $(find $DIR_A -iname 'plugins.yaml'); do
  filename=$(basename "$file_a")
  file_b="$DIR_B/$filename"
  output_file="$DIR_MERGED/$filename"
  echo $file_a $file_b
  if [[ -f "$file_b" ]]; then
    yq eval-all '
        select(fileIndex == 0) as $a |
        select(fileIndex == 1) as $b |
        $a.plugins += $b.plugins |
        $a.plugins = ($a.plugins | unique_by(.id) | sort_by(.id)) |
        $a
    ' "$file_a" "$file_b" > "$output_file"
    echo "Merged $filename with deduplicated plugins"
  else
    cp "$file_a" "$output_file"
    echo "Copied $filename from DIR_A"
  fi
done



for file_a in $(find $DIR_B -iname 'plugins.yaml'); do
  filename=$(basename "$file_b")
  if [[ ! -f "$DIR_A/$filename" ]]; then
    cp "$file_b" "$DIR_MERGED/"
    echo "Copied $filename from DIR_B"
  fi
done


for file in bundle.yaml jenkins.yaml rbac.yaml items.yaml; do
  if [[ -f "$DIR_B/$file" ]]; then
    cp "$DIR_B/$file" "$DIR_MERGED"
  else
    echo "Warning: $DIR_B/$file not found, skipping."
  fi
done

# for local dev, we dont need parent
sed -i '/^[[:space:]]*parent:[[:space:]]*"base-bundle"/ s/^/# /' $DIR_MERGED/bundle.yaml


