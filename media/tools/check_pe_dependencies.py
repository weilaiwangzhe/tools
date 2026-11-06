from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

import pefile


def exports(path: Path) -> tuple[set[bytes], set[int]]:
    pe = pefile.PE(str(path), fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"]])
    names: set[bytes] = set()
    ordinals: set[int] = set()
    for symbol in getattr(getattr(pe, "DIRECTORY_ENTRY_EXPORT", None), "symbols", []):
        if symbol.name:
            names.add(symbol.name)
        ordinals.add(symbol.ordinal)
    pe.close()
    return names, ordinals


def imports(path: Path) -> list[tuple[str, list[bytes | int]]]:
    pe = pefile.PE(str(path), fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]])
    result: list[tuple[str, list[bytes | int]]] = []
    for descriptor in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []):
        symbols: list[bytes | int] = []
        for item in descriptor.imports:
            symbols.append(item.name if item.name else item.ordinal)
        result.append((descriptor.dll.decode("ascii", errors="replace"), symbols))
    pe.close()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle")
    parser.add_argument("entry")
    args = parser.parse_args()
    root = Path(args.bundle).resolve()
    system = Path("C:/Windows/System32")
    search = [root / "PySide6", root / "shiboken6", root, system]
    pending = deque([Path(args.entry).resolve()])
    seen: set[Path] = set()
    failures = 0
    while pending:
        module = pending.popleft()
        if module in seen:
            continue
        seen.add(module)
        try:
            module_imports = imports(module)
        except pefile.PEFormatError:
            continue
        for dll_name, symbols in module_imports:
            lower = dll_name.lower()
            if lower.startswith(("api-ms-", "ext-ms-")):
                continue
            candidates = [module.parent / dll_name, *(folder / dll_name for folder in search)]
            dependency = next((item for item in candidates if item.is_file()), None)
            if dependency is None:
                print(f"MISSING DLL: {module.name} -> {dll_name}")
                failures += 1
                continue
            try:
                names, ordinals = exports(dependency)
            except pefile.PEFormatError:
                continue
            missing = [
                symbol
                for symbol in symbols
                if (isinstance(symbol, bytes) and symbol not in names)
                or (isinstance(symbol, int) and symbol not in ordinals)
            ]
            if missing:
                printable = [
                    item.decode("ascii", errors="replace") if isinstance(item, bytes) else item
                    for item in missing[:10]
                ]
                print(
                    f"MISSING EXPORT: {module.name} -> {dependency} ({len(missing)}): {printable}"
                )
                failures += 1
            if root in dependency.parents:
                pending.append(dependency.resolve())
    print(f"checked={len(seen)} failures={failures}")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
