#!/usr/bin/env python3
"""List the packages, channels and versions of a file-based operator catalog.

Reads the /configs folder of a catalog image, copied out with `podman cp`. Unlike
`oc-mirror --v2 list operators`, it does not refuse the whole catalog when one
package is invalid: it reports the stranded bundles of each channel and goes on.

Usage:
    catalog-inventory.py <configs folder> [--package NAME]

Output, one line per channel, fields separated by spaces:
    <package> <channel> default|- head=<version> versions=<v1>,<v2>,... [problem=<text>]

The problem field uses the rules of operator-registry, the library that oc-mirror uses
to load a catalog (alpha/model/model.go, Channel.Head and validateReplacesChain):
    problem=stranded:<v>,...        entries that the replaces chain from the head does not reach
    problem=multiple-heads:<v>,...  more than one entry that no other entry replaces or skips
    problem=no-head                 every entry is replaced or skipped by another one
    problem=cycle:<v>               the replaces chain comes back to this entry

Runs on Python 3.9 (RHEL 9) with PyYAML (python3-pyyaml, a dependency of ansible-core).
"""

import argparse
import json
import pathlib
import re
import sys

import yaml

JSON_SUFFIXES = {".json"}
YAML_SUFFIXES = {".yaml", ".yml"}


def read_json_stream(text, path):
    """Yield each object of a file that holds one or more JSON objects one after another."""
    decoder = json.JSONDecoder()
    pos = 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            return
        try:
            obj, pos = decoder.raw_decode(text, pos)
        except json.JSONDecodeError as err:
            raise SystemExit(f"{path}: not valid JSON at offset {pos}: {err.msg}")
        yield obj


def read_objects(configs):
    """Yield (path, object) for every catalog object under the configs folder."""
    files = sorted(p for p in configs.rglob("*") if p.is_file())
    for path in files:
        suffix = path.suffix.lower()
        if suffix in JSON_SUFFIXES:
            for obj in read_json_stream(path.read_text(encoding="utf-8"), path):
                yield path, obj
        elif suffix in YAML_SUFFIXES:
            for obj in yaml.safe_load_all(path.read_text(encoding="utf-8")):
                if obj is not None:
                    yield path, obj


def bundle_version(bundle):
    """Return the version from the olm.package property of a bundle, or None."""
    for prop in bundle.get("properties") or []:
        if prop.get("type") == "olm.package":
            return str((prop.get("value") or {}).get("version"))
    return None


def version_key(version):
    """Sort key that orders 1.10 after 1.9 and keeps text parts comparable."""
    return [(0, int(part), "") if part.isdigit() else (1, 0, part) for part in re.split(r"[.+-]", version)]


def channel_problem(entries):
    """Return (head, problem) of one channel, with the rules of operator-registry.

    The head is the one entry that no other entry replaces or skips. From the head, the
    chain follows `replaces` only, and stops at a `replaces` target that some entry skips.
    An entry that is neither on the chain nor skipped is stranded. `skipRange` does not count.
    """
    by_name = {e["name"]: e for e in entries}
    incoming, skipped = set(), set()
    for e in entries:
        if e.get("replaces"):
            incoming.add(e["replaces"])
        for skip in e.get("skips") or []:
            incoming.add(skip)
            skipped.add(skip)
    heads = sorted(n for n in by_name if n not in incoming)
    if not heads:
        return None, ("no-head", [])
    if len(heads) > 1:
        return None, ("multiple-heads", heads)

    chain = {heads[0]}
    current = by_name[heads[0]]
    while current is not None:
        target = current.get("replaces") or ""
        if not target or target in skipped:
            break
        if target in chain:
            return heads[0], ("cycle", [target])
        chain.add(target)
        current = by_name.get(target)
    stranded = sorted(set(by_name) - chain - skipped)
    return heads[0], (("stranded", stranded) if stranded else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("configs", type=pathlib.Path, help="the /configs folder copied out of the catalog image")
    parser.add_argument("--package", help="print only this package")
    args = parser.parse_args()
    if not args.configs.is_dir():
        raise SystemExit(f"not a folder: {args.configs}")

    default_channel, channels, versions = {}, {}, {}
    for _path, obj in read_objects(args.configs):
        schema = obj.get("schema")
        if schema == "olm.package":
            default_channel[obj["name"]] = obj.get("defaultChannel")
        elif schema == "olm.channel":
            channels[(obj["package"], obj["name"])] = obj.get("entries") or []
        elif schema == "olm.bundle":
            versions[obj["name"]] = bundle_version(obj)

    def show(name):
        return versions.get(name) or name

    printed = problem_channels = 0
    for (package, channel), entries in sorted(channels.items()):
        if args.package and package != args.package:
            continue
        head, problem = channel_problem(entries)
        line = [
            package,
            channel,
            "default" if default_channel.get(package) == channel else "-",
            "head=" + (show(head) if head else "-"),
            "versions=" + ",".join(sorted((show(e["name"]) for e in entries), key=version_key)),
        ]
        if problem:
            problem_channels += 1
            kind, names = problem
            line.append(f"problem={kind}" + (":" + ",".join(sorted((show(n) for n in names), key=version_key)) if names else ""))
        print(" ".join(line))
        printed += 1

    packages = {p for p, _c in channels if not args.package or p == args.package}
    print(f"{len(packages)} packages, {printed} channels, {problem_channels} with a problem", file=sys.stderr)


if __name__ == "__main__":
    main()
