"""Turns SafariConverterLib's advanced rules into PageShield's per-domain data.

usage: page-shield.py <out dir> <category>=<advanced rules file>...

Keeps extended CSS (:has, :has-text, :upward), :style() rules and calls to the eight scriptlets PageShieldScriptlets
implements; drops the rest and says how many.
"""
import collections
import json
import re
import sys

# Each scriptlet's canonical name, then the uBO and ABP spellings the converter passes through.
SCRIPTLETS = {
    "set-constant": [
        "set-constant.js", "ubo-set-constant.js", "set.js", "ubo-set.js", "ubo-set-constant", "ubo-set",
        "abp-override-property-read",
    ],
    "abort-on-property-read": [
        "abort-on-property-read.js", "ubo-abort-on-property-read.js", "aopr.js", "ubo-aopr.js",
        "ubo-abort-on-property-read", "ubo-aopr", "abp-abort-on-property-read",
    ],
    "abort-current-inline-script": [
        "abort-current-script.js", "ubo-abort-current-script.js", "acs.js", "ubo-acs.js", "ubo-abort-current-script",
        "ubo-acs", "abort-current-inline-script.js", "ubo-abort-current-inline-script.js", "acis.js", "ubo-acis.js",
        "ubo-abort-current-inline-script", "ubo-acis", "abp-abort-current-inline-script",
    ],
    "json-prune": ["json-prune.js", "ubo-json-prune.js", "ubo-json-prune", "abp-json-prune"],
    "remove-attr": ["remove-attr.js", "ubo-remove-attr.js", "ra.js", "ubo-ra.js", "ubo-remove-attr", "ubo-ra"],
    "remove-class": ["remove-class.js", "ubo-remove-class.js", "rc.js", "ubo-rc.js", "ubo-remove-class", "ubo-rc"],
    "prevent-addEventListener": [
        "addEventListener-defuser.js", "ubo-addEventListener-defuser.js", "aeld.js", "ubo-aeld.js",
        "ubo-addEventListener-defuser", "ubo-aeld", "abp-prevent-listener", "ubo-prevent-addEventListener",
    ],
    "prevent-setTimeout": [
        "no-setTimeout-if", "no-setTimeout-if.js", "ubo-no-setTimeout-if.js", "nostif.js", "ubo-nostif.js",
        "ubo-no-setTimeout-if", "ubo-nostif", "setTimeout-defuser.js", "ubo-setTimeout-defuser.js",
        "ubo-setTimeout-defuser", "std.js", "ubo-std.js", "ubo-std", "ubo-prevent-setTimeout",
    ],
}
CANONICAL = {alias: name for name, aliases in SCRIPTLETS.items() for alias in [name, *aliases]}
PROCEDURAL = {"has-text", "upward"}
ALIASES = {
    "-abp-has": "has", "-abp-contains": "has-text", "abp-contains": "has-text", "contains": "has-text",
    "nth-ancestor": "upward",
}
RULE = re.compile(r"^([^#]*)(##|#\?#|#\$#|#\$\?#|#%#)(.+)$")
PSEUDO = re.compile(r":(-?[a-z][a-z-]*)\(")


def closing(text, start):
    depth, quote, i = 0, None, start
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if quote:
            quote = None if c == quote else quote
        elif c in "\"'":
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError(text)


# Renames aliases and reports the procedural pseudo-classes left, or None when one is unsupported or sits in :not().
def normalize(selector):
    out, kinds, i = [], set(), 0
    for match in PSEUDO.finditer(selector):
        if match.start() < i:
            continue
        name = ALIASES.get(match.group(1), match.group(1))
        end = closing(selector, match.end() - 1)
        inner = selector[match.end():end]
        if name in ("has", "not", "is", "where", "nth-child", "nth-of-type", "nth-last-child", "nth-last-of-type"):
            inner, inner_kinds = normalize(inner)
            if inner is None or (name == "not" and inner_kinds):
                return None, None
            kinds |= inner_kinds
        elif name in PROCEDURAL:
            kinds.add(name)
        else:
            return None, None
        out.append(selector[i:match.start()] + ":" + name + "(" + inner + ")")
        i = end + 1
    out.append(selector[i:])
    return "".join(out), kinds


def scriptlet_call(body):
    text = body[len("//scriptlet("):-1]
    args, i = [], 0
    while i < len(text):
        quote = text[i]
        if quote in "\"'":
            j, value = i + 1, []
            while text[j] != quote:
                if text[j] == "\\" and text[j + 1] == quote:
                    j += 1
                value.append(text[j])
                j += 1
            args.append("".join(value))
            i = j + 1
        else:
            i += 1
    name = CANONICAL.get(args[0])
    return [name] + args[1:] if name else None


def main():
    out_dir, pairs = sys.argv[1], sys.argv[2:]
    for pair in pairs:
        category, path = pair.split("=", 1)
        domains = collections.defaultdict(lambda: {"css": [], "procedural": [], "scriptlets": []})
        kept, dropped = collections.Counter(), collections.Counter()
        for line in open(path):
            line = line.strip()
            match = RULE.match(line)
            if not match:
                dropped["network"] += 1
                continue
            hosts, separator, body = match.groups()
            hosts = hosts.split(",") if hosts else [""]
            if any(host.startswith("~") for host in hosts):
                dropped["negated domain"] += 1
                continue
            if separator == "#%#":
                if not body.startswith("//scriptlet("):
                    dropped["script"] += 1
                    continue
                call = scriptlet_call(body)
                if call is None:
                    dropped["scriptlet " + body.split(",")[0][len("//scriptlet("):].strip("\"')")] += 1
                    continue
                kind, value = "scriptlets", call
            elif separator in ("#$#", "#$?#"):
                brace = body.index("{")
                selector, style = normalize(body[:brace].strip())
                if selector is None or style or "remove:" in body[brace:].replace(" ", ""):
                    dropped["style"] += 1
                    continue
                kind, value = "css", selector + " " + body[brace:].strip()
            else:
                selector, found = normalize(body)
                if selector is None:
                    dropped["extended css"] += 1
                    continue
                if found:
                    kind, value = "procedural", selector
                else:
                    kind, value = "css", selector + " { display: none !important; }"
            kept[kind] += 1
            for host in hosts:
                domains[host][kind].append(value)
        data = {host: {k: v for k, v in rules.items() if v} for host, rules in sorted(domains.items())}
        for rules in data.values():
            if "css" in rules:
                rules["css"] = "\n".join(rules["css"])
        json.dump(data, open(f"{out_dir}/{category}.json", "w"), separators=(",", ":"), sort_keys=True)
        print(f"{category}: kept {dict(kept)}, {len(data)} domains; dropped {dict(dropped.most_common())}")


main()
