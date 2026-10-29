#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load common environment variables
source "${SCRIPT_DIR}/.env"

# Derive full paths based on environment variables
ITEMS_YAML="${CASC_BUNDLES_PATH}/${ITEMS_YAML}"
OUTDIR="${CASC_BUNDLES_PATH}/splitdir"
SCHEMA="${SCRIPT_DIR}/items-schema.json"
mkdir -p "$OUTDIR"

# Remove output of previous runs so the directory reflects exactly this run
find "$OUTDIR" -maxdepth 1 -type f -name '*.yaml' -delete

COUNT="$(yq e '.items | length' "$ITEMS_YAML")"
if [[ "$COUNT" -eq 0 ]]; then
  echo "No items found in $ITEMS_YAML" >&2
  exit 1
fi

# items.yaml is shaped as { items: [ <item>, ... ], removeStrategy?, root? } and
# each output must keep that shape (items-schema.json: "items" is a required,
# non-empty array). Every item, at any nesting depth, gets its own file shaped
# like controller1.yaml:
#   removeStrategy: {rbac: SYNC, items: NONE}   (fixed default)
#   <other root keys such as root, copied unchanged>
#   items:
#     - <ancestor folder: all keys except items/properties>
#       items:
#         - <item>
# A container (folder) gets its own file too, with its children removed
# (they live in their own files) and its properties kept.
#
# jq does the splitting: emits one {file, doc} JSON line per item.
JQ_PROGRAM='
  def stub: with_entries(select(.key != "items" and .key != "properties"));
  # chain = [top-level item, ..., item]; wrap item in its ancestors
  def build($chain):
    ($chain | length) as $n
    | reduce range($n - 2; -1; -1) as $i (
        ($chain[-1] | del(.items));
        . as $inner | ($chain[$i] | stub) + { items: [ $inner ] }
      );
  # item without nested items is kept whole (del(.items) is a no-op for it)
  def nodes($chain):
    ($chain + [.]) as $c
    | { chain: $c },
      ((.items // [])[] | nodes($c));
  . as $root
  | ($root | with_entries(select(.key != "items" and .key != "removeStrategy"))) as $rest
  | $root.items | to_entries[]
  | .key as $top
  | .value | nodes([])
  | {
      file: (
        ["\($top | tostring | if length < 3 then ("000" + .)[-3:] else . end)", .chain[0].kind,
         (.chain | map(.name) | join("-"))] | join(".")
      ),
      doc: (
        { removeStrategy: { rbac: "SYNC", items: "NONE" } } + $rest
        + { items: [ ( .chain as $c | build($c) ) ] }
      )
    }
'

yq e -o=json -I0 '.' "$ITEMS_YAML" | jq -c "$JQ_PROGRAM" | while IFS= read -r line; do
  # Safe filenames; keep dots/dashes/underscores
  file="$(jq -r '.file' <<<"$line" | sed 's#[^A-Za-z0-9._-]#_#g')"
  jq '.doc' <<<"$line" | yq e -p=json -o=yaml -I 2 '.' - > "$OUTDIR/${file}.yaml"
done

# Fail if any resulting file does not match the items schema
check-jsonschema --schemafile "$SCHEMA" "$OUTDIR"/*.yaml
