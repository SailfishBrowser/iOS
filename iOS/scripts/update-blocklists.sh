#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="v4.3.1"
CONVERTER_DIR=".tools/SafariConverterLib"
CONVERTER="$CONVERTER_DIR/.build/release/ConverterTool"
OUT="SailBrowser/Resources/Blocklists"
LIMIT=150000

NAMES=(easylist annoyances easyprivacy easylist-cookie)
CATEGORIES=(ads ads trackers cookieBanners)
URLS=(
  "https://easylist.to/easylist/easylist.txt"
  "https://secure.fanboy.co.nz/fanboy-annoyance.txt"
  "https://easylist.to/easylist/easyprivacy.txt"
  "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"
)

if [ ! -d "$CONVERTER_DIR" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/AdguardTeam/SafariConverterLib.git "$CONVERTER_DIR"
fi
swift build -c release --product ConverterTool --package-path "$CONVERTER_DIR"

mkdir -p .tools/lists "$OUT"

for i in "${!NAMES[@]}"; do
  curl -fsSL "${URLS[$i]}" -o ".tools/lists/${NAMES[$i]}.txt"
done

# Fanboy Annoyances embeds the whole cookie list. Its rules come out here, so cookie banners follow their own toggle.
python3 -I - .tools/lists/annoyances.txt .tools/lists/easylist-cookie.txt <<'PY'
import sys
cookie = {line for line in open(sys.argv[2]) if not line.startswith(("!", "["))}
kept = [line for line in open(sys.argv[1]) if line not in cookie]
open(sys.argv[1], "w").writelines(kept)
PY

entries=()
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  "$CONVERTER" convert --safari-version 26 --advanced-blocking false \
    --input-path ".tools/lists/$name.txt" --safari-rules-json-path "$OUT/$name.json" \
    --advanced-blocking-rules-path ".tools/$name.advanced.txt"
  count=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$OUT/$name.json")
  echo "$name: $count rules"
  if [ "$count" -ge "$LIMIT" ]; then
    echo "$name has $count rules, at or over the WebKit limit of $LIMIT" >&2
    exit 1
  fi
  entries+=("{\"name\":\"$name\",\"category\":\"${CATEGORIES[$i]}\"}")
done

lists=()
for name in "${NAMES[@]}"; do lists+=("$OUT/$name.json"); done
python3 -I scripts/tracker-domains.py "$OUT/tracker-domains.txt" "${lists[@]}"
echo "tracker-domains: $(wc -l < "$OUT/tracker-domains.txt") domains"
printf '{"version":"%s","lists":[%s]}\n' "$(date +%Y.%m.%d)" "$(IFS=,; echo "${entries[*]}")" > "$OUT/manifest.json"
cat "$OUT/manifest.json"

bash scripts/update-page-shield.sh
