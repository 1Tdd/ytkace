#!/usr/bin/env python3
"""Check the tweak's hook targets against the Objective-C metadata of a YouTube IPA.

Hooks fail silently at runtime when YouTube renames a class or removes a method.
This reads the IPA without running anything from it and lists those targets.

A method missing from a class whose parent is a system class may simply be
inherited, so such entries are known problems to review rather than proof of a
break. Accepted entries live in Tools/hook_baselines/<version>.txt: only entries
outside the baseline fail the check. A version without a baseline is only reported.
"""

import argparse
import pathlib
import plistlib
import re
import struct
import sys
import zipfile
from dataclasses import dataclass, field

MAGIC_64 = 0xFEEDFACF
MAGIC_FAT = 0xBEBAFECA
CPU_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_ENCRYPTION_INFO_64 = 0x2C
# Only these prefixes belong to the YouTube binary; other classes come from the system.
APP_CLASS = re.compile(r"^(YT|ML|MDX|ELM|HAM|GIM|SSO|_AS|AS)[A-Z]")
HOOK_CALL = re.compile(r'YTKACEInstall(Instance|Class)Hook\(\s*@"([^"]+)"\s*,\s*@"([^"]+)"', re.S)


@dataclass
class ClassTable:
    instance: dict = field(default_factory=dict)
    meta: dict = field(default_factory=dict)
    parents: dict = field(default_factory=dict)

    def resolve(self, name):
        """Follow the same fallback as YTKACEInstallHook."""
        if name in self.instance:
            return name
        return name + "Impl" if name + "Impl" in self.instance else None

    def responds(self, name, selector, class_method):
        table = self.meta if class_method else self.instance
        seen = set()
        while name and name not in seen:
            seen.add(name)
            if selector in table.get(name, ()):
                return True
            name = self.parents.get(name)
        return False


def parse_hooks(root):
    """Return {(kind, class, selector)} for hooks whose target is written literally."""
    hooks = set()
    for path in sorted(pathlib.Path(root).rglob("*.mm")):
        text = path.read_text(encoding="utf-8", errors="replace")
        hooks.update(HOOK_CALL.findall(text))
    return hooks


def find_problems(hooks, table):
    problems = set()
    for kind, name, selector in hooks:
        target = table.resolve(name)
        if target is None:
            if APP_CLASS.match(name):
                problems.add(f"missing-class {name} {selector}")
        elif not table.responds(target, selector, kind == "Class"):
            problems.add(f"missing-method {name} {selector}")
    return problems


def read_baseline(path):
    if not path.exists():
        return None
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")}


class MachO:
    def __init__(self, data):
        self.data = data
        if struct.unpack_from("<I", data)[0] != MAGIC_64:
            raise ValueError("not a thin 64-bit Mach-O")
        self.segments = []
        self.sections = {}
        self.encrypted = False
        count = struct.unpack_from("<I", data, 16)[0]
        offset = 32
        for _ in range(count):
            command, size = struct.unpack_from("<II", data, offset)
            if command == LC_SEGMENT_64:
                self._read_segment(offset)
            elif command == LC_ENCRYPTION_INFO_64:
                self.encrypted = struct.unpack_from("<I", data, offset + 16)[0] != 0
            offset += size
        self.base = min((s[0] for s in self.segments if s[3] > 0), default=0)

    def _read_segment(self, offset):
        address, _, file_offset, file_size = struct.unpack_from("<QQQQ", self.data, offset + 24)
        self.segments.append((address, address + file_size, file_offset, file_size))
        cursor = offset + 72
        for _ in range(struct.unpack_from("<I", self.data, offset + 64)[0]):
            name = self.data[cursor:cursor + 16].rstrip(b"\0").decode()
            section_address, section_size = struct.unpack_from("<QQ", self.data, cursor + 32)
            self.sections.setdefault(name, []).append((section_address, section_size))
            cursor += 80

    def offset_of(self, address):
        for start, end, file_offset, _ in self.segments:
            if start <= address < end:
                return address - start + file_offset
        return None

    def pointer(self, address):
        position = self.offset_of(address)
        if position is None:
            return 0
        raw = struct.unpack_from("<Q", self.data, position)[0]
        if raw >> 63:  # Bound to another image, such as a system superclass.
            return 0
        target = raw & 0xFFFFFFFFF
        return target + self.base if target and target < self.base else target

    def string(self, address):
        position = self.offset_of(address)
        if position is None:
            return None
        end = self.data.find(b"\0", position, position + 4096)
        return self.data[position:end].decode("utf-8", "replace") if end >= 0 else None

    def _method_names(self, address):
        position = self.offset_of(address) if address else None
        if position is None:
            return set()
        size, count = struct.unpack_from("<II", self.data, position)
        names = set()
        for index in range(min(count, 20000)):
            item = address + 8 + index * (size & 0xFFFC)
            if size & 0x80000000:
                reference = item + struct.unpack_from("<i", self.data, self.offset_of(item))[0]
                names.add(self.string(reference) if size & 0x40000000 else self.string(self.pointer(reference)))
            else:
                names.add(self.string(self.pointer(item)))
        return names

    def _property_names(self, address):
        position = self.offset_of(address) if address else None
        if position is None:
            return set()
        size, count = struct.unpack_from("<II", self.data, position)
        return {self.string(self.pointer(address + 8 + index * size)) for index in range(min(count, 20000))}

    def _class_record(self, address):
        read_only = self.pointer(address + 32) & ~7
        if self.offset_of(read_only) is None:
            return None
        return {"isa": self.pointer(address), "super": self.pointer(address + 8),
                "name": self.string(self.pointer(read_only + 24)),
                "methods": self.pointer(read_only + 32), "properties": self.pointer(read_only + 64)}

    def _list(self, section):
        for address, size in self.sections.get(section, []):
            for index in range(size // 8):
                yield self.pointer(address + index * 8)

    def class_table(self):
        table = ClassTable()
        names, supers = {}, {}
        for address in self._list("__objc_classlist"):
            record = self._class_record(address)
            if not record or not record["name"]:
                continue
            name = record["name"]
            names[address] = name
            supers[name] = record["super"]
            table.instance[name] = self._method_names(record["methods"]) | self._property_names(record["properties"])
            metaclass = self._class_record(record["isa"]) if record["isa"] else None
            table.meta[name] = self._method_names(metaclass["methods"]) if metaclass else set()
        for category in self._list("__objc_catlist"):
            name = names.get(self.pointer(category + 8))
            if name:
                table.instance[name] |= self._method_names(self.pointer(category + 16))
                table.meta[name] |= self._method_names(self.pointer(category + 24))
        table.parents = {name: names.get(parent) for name, parent in supers.items()}
        return table


def thin_arm64(data):
    if struct.unpack_from("<I", data)[0] != MAGIC_FAT:
        return data
    for index in range(struct.unpack_from(">I", data, 4)[0]):
        cpu, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + index * 20)
        if cpu == CPU_ARM64:
            return data[offset:offset + size]
    raise ValueError("no arm64 slice")


def read_ipa(path):
    with zipfile.ZipFile(path) as archive:
        info = next(name for name in archive.namelist()
                    if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name))
        plist = plistlib.loads(archive.read(info))
        binary = archive.read(info.rsplit("/", 1)[0] + "/" + plist["CFBundleExecutable"])
    return plist["CFBundleShortVersionString"], MachO(thin_arm64(binary))


def report(version, hooks, problems, baseline, new, fixed):
    lines = [f"YouTube {version}: {len(hooks)} hook targets written literally, {len(problems)} not found"]
    if baseline is None:
        lines.append(f"No baseline for {version}: nothing fails. Every entry below needs review.")
    else:
        lines.append(f"Baseline: {len(baseline)} accepted, {len(new)} new, {len(fixed)} no longer needed")
    for title, entries in (("New" if baseline is not None else "Not found", new),
                           ("No longer in the IPA's problem list, remove from the baseline", fixed)):
        if entries:
            lines.append(f"{title}:")
            lines.extend(f"  {entry}" for entry in sorted(entries))
    return "\n".join(lines)


def main(argv=None):
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("ipa", type=pathlib.Path)
    parser.add_argument("--source", type=pathlib.Path, default=root / "Tweak")
    parser.add_argument("--baselines", type=pathlib.Path, default=root / "Tools" / "hook_baselines")
    parser.add_argument("--write-baseline", action="store_true", help="accept the current problems for this version")
    arguments = parser.parse_args(argv)

    version, binary = read_ipa(arguments.ipa)
    if binary.encrypted:
        print("The IPA's binary is encrypted, so its classes cannot be read.", file=sys.stderr)
        return 2
    table = binary.class_table()
    if not table.instance:
        print("No Objective-C classes could be read from the IPA.", file=sys.stderr)
        return 2
    hooks = parse_hooks(arguments.source)
    problems = find_problems(hooks, table)
    path = arguments.baselines / f"{version}.txt"
    if arguments.write_baseline:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{entry}\n" for entry in sorted(problems)), encoding="utf-8", newline="\n")
        print(f"Wrote {len(problems)} entries to {path}")
        return 0
    baseline = read_baseline(path)
    new = problems - (baseline or set())
    fixed = (baseline or set()) - problems
    print(report(version, hooks, problems, baseline, new, fixed))
    return 1 if baseline is not None and new else 0


if __name__ == "__main__":
    sys.exit(main())
