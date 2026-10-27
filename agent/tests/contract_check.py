from __future__ import annotations

"""Compares a produced snapshot with a Swift fixture: same keys at every level, same JSON types."""


def _kind(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    return {int: "int", float: "float", str: "str", list: "list", dict: "dict"}[type(v)]


def same_shape(produced, fixture, path: str = "") -> list[str]:
    diffs: list[str] = []
    if fixture is None:
        return diffs
    pk, fk = _kind(produced), _kind(fixture)
    if pk == "null":
        return diffs  # an optional value the fixture happens to fill
    if pk != fk:
        return [f"{path or '<root>'}: {pk} != {fk}"]
    if fk == "dict":
        for key in fixture:
            sub = f"{path}.{key}" if path else key
            if key not in produced:
                diffs.append(f"{sub}: missing")
            else:
                diffs += same_shape(produced[key], fixture[key], sub)
        for key in produced:
            if key not in fixture:
                diffs.append(f"{f'{path}.{key}' if path else key}: extra")
    elif fk == "list" and fixture and produced:
        diffs += same_shape(produced[0], fixture[0], f"{path}[0]")
    return diffs
