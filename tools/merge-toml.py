#!/usr/bin/env python3
"""
Deep merge two TOML documents while preserving TOML formatting with tomlkit.

Important tomlkit behavior:
- AoT (array-of-tables) supports append/iteration but NOT indexed assignment.
- Therefore matching AoT entries must be merged in place rather than using:
      base[index] = merged_table
"""

from __future__ import annotations

import sys
from pathlib import Path
from collections.abc import Mapping

from tomlkit import parse, dumps
from tomlkit.items import AoT, Table


# Keys commonly used by WSO2 arrays-of-tables to identify one logical entry.
IDENTITY_KEYS = (
    "name",
    "id",
    "context",
    "class",
    "type",
    "hostname",
    "key",
)


def primitive(value):
    """Return a comparable Python value when possible."""
    try:
        return value.unwrap()
    except AttributeError:
        return value


def is_mapping(value):
    return isinstance(value, Mapping) or isinstance(value, Table)


def identity_for(table):
    """
    Return (key, value) for the first stable identifier present in an AoT item.
    """
    if not is_mapping(table):
        return None

    for key in IDENTITY_KEYS:
        if key in table:
            return key, primitive(table[key])

    return None


def find_matching_table(base_aot: AoT, overlay_table):
    """
    Find an existing AoT table corresponding to overlay_table.

    Prefer a shared stable identity key. If no identity exists, do not guess:
    return None and let the caller append the overlay item.
    """
    ident = identity_for(overlay_table)
    if ident is None:
        return None

    key, wanted = ident

    for candidate in base_aot:
        if is_mapping(candidate) and key in candidate:
            if primitive(candidate[key]) == wanted:
                return candidate

    return None


def merge_aot(base: AoT, overlay: AoT):
    """
    Merge an array-of-tables.

    Never assign base[index] = ... because tomlkit AoT.__setitem__ is
    intentionally unsupported.
    """
    for overlay_item in overlay:
        match = find_matching_table(base, overlay_item)

        if match is None:
            base.append(overlay_item)
        else:
            # Mutate the matching table IN PLACE.
            merge(match, overlay_item)

    return base


def merge(base, overlay):
    """
    Deep merge overlay into base.

    - Mapping/Table + Mapping/Table => recursive merge
    - AoT + AoT => match entries by stable identity and mutate in place
    - Other values/arrays => overlay replaces base
    """
    if isinstance(base, AoT) and isinstance(overlay, AoT):
        return merge_aot(base, overlay)

    if is_mapping(base) and is_mapping(overlay):
        for key, overlay_value in overlay.items():
            if key not in base:
                base[key] = overlay_value
                continue

            base_value = base[key]

            if isinstance(base_value, AoT) and isinstance(overlay_value, AoT):
                merge_aot(base_value, overlay_value)

            elif is_mapping(base_value) and is_mapping(overlay_value):
                # Mutate nested table in place.
                merge(base_value, overlay_value)

            else:
                # Scalar / ordinary array / incompatible type:
                # overlay intentionally wins.
                base[key] = overlay_value

        return base

    return overlay


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: merge-toml.py BASE.toml OVERLAY.toml OUTPUT.toml",
            file=sys.stderr,
        )
        raise SystemExit(2)

    base_path = Path(sys.argv[1])
    overlay_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3])

    base = parse(base_path.read_text())
    overlay = parse(overlay_path.read_text())

    merge(base, overlay)

    output_path.write_text(dumps(base))


if __name__ == "__main__":
    main()
