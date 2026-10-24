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

Usage: make_ps_action.py <src.atn> <out.atn> <set_name> <action_name> <filter_menu_item> [fn_key]

fn_key (optional): F-key number for the action's Shift+F<n> shortcut,
replacing whatever the source action was recorded with. The 6 bytes before
the action name string are: fnKey int16, shift byte, cmd byte, colorIndex
int16 - only the first four are rewritten.
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


def set_shortcut(data, action_name, fn_key):
    """Rewrite the fnKey/shift/cmd header immediately preceding the action name."""
    marker = unicode_string(action_name)
    pos = data.find(marker)
    if pos < 6:
        sys.exit(f"error: cannot locate action '{action_name}' to set its shortcut")
    return data[: pos - 6] + struct.pack(">HBB", fn_key, 1, 0) + data[pos - 2 :]


def main():
    if len(sys.argv) not in (6, 7):
        sys.exit(__doc__)
    src, out, set_name, action_name, filter_item = sys.argv[1:6]
    fn_key = int(sys.argv[6]) if len(sys.argv) == 7 else None

    with open(src, "rb") as f:
        data = f.read()

    data = replace_string(data, "Aagedal", set_name)
    data = replace_string(data, "Anonymizer Action", action_name)
    data = replace_string(data, "Multi-Layer Anonymizer...", filter_item)
    if fn_key is not None:
        data = set_shortcut(data, action_name, fn_key)

    with open(out, "wb") as f:
        f.write(data)
    shortcut = f", Shift+F{fn_key}" if fn_key is not None else ""
    print(f"wrote {out} (set '{set_name}', action '{action_name}', filter '{filter_item}'{shortcut})")


if __name__ == "__main__":
    main()
