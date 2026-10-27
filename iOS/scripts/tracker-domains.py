import json
import re
import sys

# Domains every one of whose loads a list blocks: unconditional block rules of AdGuard's "||domain^" form, minus any
# domain an exception rule names, so a count built on them never claims a load the lists let through. A rule of the
# form ".domain/", as EasyPrivacy writes google-analytics.com, blocks the domain's subdomains only, and is written with
# a leading dot.
ANCHORED = re.compile(r"^\^\[\^:\]\+://\+\(\[\^:/\]\+\\\.\)\?((?:[a-z0-9-]+\\\.)+[a-z0-9-]+)\[/:\]$")
SUBDOMAINS = re.compile(r"^\\\.((?:[a-z0-9-]+\\\.)+[a-z0-9-]+)\\/$")
PLAIN_TRIGGER = {"url-filter", "url-filter-is-case-sensitive"}

blocked, excepted = set(), set()
for path in sys.argv[2:]:
    for rule in json.load(open(path)):
        url_filter = rule["trigger"].get("url-filter", "")
        kind = rule["action"]["type"]
        match = ANCHORED.match(url_filter)
        subdomains = SUBDOMAINS.match(url_filter)
        if match:
            domain = match.group(1).replace("\\.", ".")
            if kind == "block" and set(rule["trigger"]) <= PLAIN_TRIGGER:
                blocked.add(domain)
            elif kind == "ignore-previous-rules":
                excepted.add(domain)
        elif subdomains and kind == "block" and set(rule["trigger"]) <= PLAIN_TRIGGER:
            blocked.add("." + subdomains.group(1).replace("\\.", "."))

with open(sys.argv[1], "w") as out:
    out.write("".join(f"{domain}\n" for domain in sorted(blocked) if domain.lstrip(".") not in excepted))
