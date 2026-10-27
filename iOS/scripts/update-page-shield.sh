#!/bin/bash
# Builds PageShield's data from the lists update-blocklists.sh downloaded: the converter runs again with advanced
# blocking on, and the rules WebKit's lists cannot express become per-domain CSS, procedural selectors and scriptlets.
set -euo pipefail
cd "$(dirname "$0")/.."

CONVERTER=".tools/SafariConverterLib/.build/release/ConverterTool"
MANIFEST="SailBrowser/Resources/Blocklists/manifest.json"
OUT="SailBrowser/Resources/PageShield"

mkdir -p .tools/advanced "$OUT"

# YouTube rules written for Sailfish from the player response's public field names; EasyList ships none.
cat > .tools/advanced/youtube.txt <<'RULES'
youtube.com,youtubekids.com,youtube-nocookie.com#%#//scriptlet('json-prune', 'playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots')
youtube.com,youtubekids.com,youtube-nocookie.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined')
youtube.com,youtubekids.com,youtube-nocookie.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.adSlots', 'undefined')
youtube.com,youtubekids.com,youtube-nocookie.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.playerAds', 'undefined')
RULES

pairs=()
for category in ads trackers cookieBanners; do
  : > ".tools/advanced/$category.txt"
  for name in $(python3 -I -c 'import json,sys; print(" ".join(l["name"] for l in json.load(open(sys.argv[1]))["lists"] if l["category"] == sys.argv[2]))' "$MANIFEST" "$category"); do
    "$CONVERTER" convert --safari-version 26 --advanced-blocking true --input-path ".tools/lists/$name.txt" \
      --safari-rules-json-path ".tools/advanced/$name.json" --advanced-blocking-rules-path ".tools/advanced/$name.txt"
    # The converter ends its file without a newline, so awk adds one before the next list joins it.
    awk 1 ".tools/advanced/$name.txt" >> ".tools/advanced/$category.txt"
  done
  pairs+=("$category=.tools/advanced/$category.txt")
done
cat .tools/advanced/youtube.txt >> .tools/advanced/ads.txt

python3 -I scripts/page-shield.py "$OUT" "${pairs[@]}"
