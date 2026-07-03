#!/usr/bin/env python3
"""Rebrand the bundled Photoshop action (.atn) for a branded edition.

The source action (ps/actions/AagedalAnonymizer.atn) is authored against the
OSS edition. Its .atn stream stores every string with a length prefix and no
global offsets, so specific strings can be swapped without a full parser:

  - the action set name shown in the Actions panel ("Aagedal")
  - the action name ("Anonymizer Action")
  - the filter menu item the action plays ("Multi-Layer Anonymizer...") -
    recorded by name (Fltr/Usng) because the filter has no scripting
    terminology; it must match the edition's PiPL Name exactly.

The PS 2025+ "modernized action data" sidecar blob (tdta, own length field)
contains no branding and is left untouched.

Usage: make_ps_action.py <src.atn> <out.atn> <set_name> <action_name> <filter_menu_item>
"""
import struct
import sys


def unicode_string(s):
    """4-byte character count (including the NUL terminator) + UTF-16BE + NUL."""
    return struct.pack(">I", len(s) + 1) + s.encode("utf-16-be") + b"\x00\x00"


def replace_string(data, old, new):
    if old == new:
        return data
    old_bytes = unicode_string(old)
    new_bytes = unicode_string(new)
    count = data.count(old_bytes)
    if count != 1:
        sys.exit(
            f"error: expected exactly 1 occurrence of '{old}' in the action, "
            f"found {count} - the source .atn changed, update this script"
        )
    return data.replace(old_bytes, new_bytes)


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    src, out, set_name, action_name, filter_item = sys.argv[1:6]

    with open(src, "rb") as f:
        data = f.read()

    data = replace_string(data, "Aagedal", set_name)
    data = replace_string(data, "Anonymizer Action", action_name)
    data = replace_string(data, "Multi-Layer Anonymizer...", filter_item)

    with open(out, "wb") as f:
        f.write(data)
    print(f"wrote {out} (set '{set_name}', action '{action_name}', filter '{filter_item}')")


if __name__ == "__main__":
    main()
