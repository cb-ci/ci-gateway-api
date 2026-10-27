#! /bin/bash

 #!/bin/bash

SUFFIX="-core-casc-export-jenkins"

for dir in *"$SUFFIX"; do
  # Check if it's a directory
  if [ -d "$dir" ]; then
    # Remove the suffix
    new_name="${dir%"$SUFFIX"}"

    # Rename the directory
    echo "Renaming: $dir → $new_name"
    mv "$dir" "$new_name"
  fi
done