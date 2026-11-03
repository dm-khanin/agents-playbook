#!/usr/bin/env python3
"""Findings a Copilot review keeps in its body instead of in review threads.

Reads one review body on stdin. The body can say "No open issues" and show zero threads while still carrying
a real finding, so pr-state.sh and pr-findings.sh read it through this parser.

Two shapes, five spellings, all seen on real reviews in 2026-09/10:
- nested: an outer <details> whose summary is "N previously missed issue(s)" or "Previously missed (N)" holds
  one inner <details> per finding: severity icon and title in its summary, then `path:line`, then the text.
- flat: a <details> summarised "Suppressed comments (N)" or "Comments suppressed due to low confidence (N)",
  or a "### Suppressed comments (N)" heading, followed by `**path:line**` and a `* text` line per finding.
Paths arrive with zero-width spaces between segments (src/<U+200B>core/...); they are removed.

Usage: copilot_body.py [--format json|count|effort|lines|full] < body
"""

import argparse
import json
import re
import sys

ZERO_WIDTH = dict.fromkeys(map(ord, "​‌‍⁠﻿"))
DETAILS_TAG = re.compile(r"<(/?)details\b[^>]*>", re.I)
SUMMARY = re.compile(r"<summary\b[^>]*>(.*?)</summary>", re.I | re.S)
SEVERITY = re.compile(r'alt="(\w+) severity"', re.I)
BACKTICK_LOCATION = re.compile(r"`([^`\n]+:\d+(?:-\d+)?)`")
FLAT_FINDING = re.compile(r"^\*\*([^*\n]+?:\d+(?:-\d+)?)\*\*[ \t]*\n\* (.+)$", re.M)
SUPPRESSED_HEADING = re.compile(r"^#+\s*Suppressed comments\s*\(\d+\)\s*$", re.I | re.M)
SECTION_END = re.compile(r"\n#+ |</details>|\n- \*\*Files reviewed|\n---")
EFFORT = re.compile(r"Review effort(?: level)?:?(?:\*\*)?:?\s*([A-Za-z]+)")


def clean(text):
    return re.sub(r"\s+", " ", text.translate(ZERO_WIDTH)).strip()


def strip_tags(html):
    html = re.sub(r"<picture\b.*?</picture>", " ", html, flags=re.I | re.S)
    return clean(re.sub(r"<[^>]+>", " ", html))


def kind_of(summary_text):
    text = summary_text.lower()
    if "missed" in text:
        return "missed"
    if "suppressed" in text:
        return "suppressed"
    return None


def details_blocks(body):
    """Every <details> block as {start, end, parent}: content offsets and the enclosing block's index."""
    blocks, stack = [], []
    for match in DETAILS_TAG.finditer(body):
        if match.group(1) == "":
            blocks.append({"start": match.end(), "end": None, "parent": stack[-1] if stack else None})
            stack.append(len(blocks) - 1)
        elif stack:
            blocks[stack.pop()]["end"] = match.start()
    for index in stack:
        blocks[index]["end"] = len(body)
    return blocks


def own_summary(body, block, blocks, index):
    """The block's own summary: the first one before any child block opens."""
    content = body[block["start"]:block["end"]]
    children = [b["start"] for b in blocks if b["parent"] == index]
    if children:
        content = content[: min(children) - block["start"]]
    match = SUMMARY.search(content)
    return match.group(1) if match else ""


def flat_findings(text, kind):
    findings = []
    for location, line in FLAT_FINDING.findall(text):
        sentence = clean(line)
        title = re.split(r"(?<=[.!?])\s", sentence, maxsplit=1)[0]
        findings.append({"kind": kind, "severity": None, "location": clean(location), "title": title[:160],
                         "text": sentence})
    return findings


def nested_finding(body, block, kind):
    content = body[block["start"]:block["end"]]
    summary = SUMMARY.search(content)
    head = summary.group(1) if summary else ""
    rest = content[summary.end():] if summary else content
    severity = SEVERITY.search(head)
    location = BACKTICK_LOCATION.search(rest)
    text = rest[location.end():] if location else rest
    return {"kind": kind, "severity": severity.group(1) if severity else None,
            "location": clean(location.group(1)) if location else None, "title": strip_tags(head),
            "text": strip_tags(text)}


def parse(body):
    findings = []
    blocks = details_blocks(body)
    for index, block in enumerate(blocks):
        kind = kind_of(strip_tags(own_summary(body, block, blocks, index)))
        if not kind:
            continue
        children = [b for b in blocks if b["parent"] == index]
        if children:
            findings.extend(nested_finding(body, child, kind) for child in children)
        else:
            findings.extend(flat_findings(body[block["start"]:block["end"]], kind))
    for heading in SUPPRESSED_HEADING.finditer(body):
        tail = body[heading.end():]
        end = SECTION_END.search(tail)
        findings.extend(flat_findings(tail[: end.start()] if end else tail, "suppressed"))
    effort = EFFORT.search(body)
    return {"effort": effort.group(1) if effort else None, "findings": findings}


def count_line(findings):
    if not findings:
        return "0"
    by_kind = {kind: sum(1 for f in findings if f["kind"] == kind) for kind in ("missed", "suppressed")}
    return f"{len(findings)} (missed {by_kind['missed']}, suppressed {by_kind['suppressed']})"


def finding_line(finding):
    severity = f" {finding['severity']}" if finding["severity"] else ""
    return f"  - [{finding['kind']}{severity}] {finding['location'] or '?'} — {finding['title']}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--format", choices=["json", "count", "effort", "lines", "full"], default="json")
    fmt = parser.parse_args().format
    result = parse(sys.stdin.read())
    findings = result["findings"]
    if fmt == "json":
        print(json.dumps(result, ensure_ascii=False))
    elif fmt == "count":
        print(count_line(findings))
    elif fmt == "effort":
        print(result["effort"] or "")
    else:
        for finding in findings:
            print(finding_line(finding))
            if fmt == "full" and finding["text"]:
                print(f"      {finding['text']}")


if __name__ == "__main__":
    main()
