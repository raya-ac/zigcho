"""Field-scoped normalization and first-divergence reporting.

Nondeterminism is never removed globally.  Every replacement is attached to a
declared object path so a new token, timestamp, or identity field cannot become
invisible by accident.
"""

from __future__ import annotations

import copy
import re
from dataclasses import dataclass
from typing import Any, Mapping, Sequence


class NormalizationError(ValueError):
    pass


@dataclass(frozen=True)
class Difference:
    path: str
    left: Any
    right: Any
    reason: str

    def as_dict(self) -> dict[str, Any]:
        return {"path": self.path, "left": self.left, "right": self.right, "reason": self.reason}


def apply_rules(value: Any, rules: Sequence[Mapping[str, Any]], variables: Mapping[str, Any]) -> Any:
    normalized = copy.deepcopy(value)
    for rule in rules:
        path = rule["path"].split(".")
        _apply(normalized, path, rule, variables, display_path="$" )
    return normalized


def _apply(
    current: Any,
    path: list[str],
    rule: Mapping[str, Any],
    variables: Mapping[str, Any],
    *,
    display_path: str,
) -> None:
    if not path:
        raise NormalizationError("normalizer cannot replace the document root")
    part = path[0]
    tail = path[1:]
    if part == "*":
        if isinstance(current, list):
            for index, child in enumerate(current):
                if tail:
                    _apply(child, tail, rule, variables, display_path=f"{display_path}[{index}]")
                else:
                    current[index] = _replacement(child, rule, variables, f"{display_path}[{index}]")
            return
        if isinstance(current, dict):
            for key in sorted(current):
                if tail:
                    _apply(current[key], tail, rule, variables, display_path=f"{display_path}.{key}")
                else:
                    current[key] = _replacement(current[key], rule, variables, f"{display_path}.{key}")
            return
        raise NormalizationError(f"{display_path} is not a collection for wildcard path")

    if isinstance(current, list):
        try:
            index = int(part)
            child = current[index]
        except (ValueError, IndexError) as exc:
            raise NormalizationError(f"{display_path}[{part}] does not exist") from exc
        if tail:
            _apply(child, tail, rule, variables, display_path=f"{display_path}[{index}]")
        else:
            current[index] = _replacement(child, rule, variables, f"{display_path}[{index}]")
        return

    if not isinstance(current, dict) or part not in current:
        raise NormalizationError(f"{display_path}.{part} does not exist")
    if tail:
        _apply(current[part], tail, rule, variables, display_path=f"{display_path}.{part}")
    else:
        current[part] = _replacement(current[part], rule, variables, f"{display_path}.{part}")


def _replacement(value: Any, rule: Mapping[str, Any], variables: Mapping[str, Any], path: str) -> Any:
    kind = rule["kind"]
    if kind == "ignore":
        return f"<ignored:{rule['path']}>"
    if kind == "screenshot_filename":
        if not isinstance(value, str):
            raise NormalizationError(f"{path}: screenshot filename must be text")
        match = re.fullmatch(r"[A-Za-z0-9_-]{8}\.(jpeg|png)", value)
        if match is None:
            raise NormalizationError(f"{path}: invalid generated screenshot filename")
        return f"<generated-screenshot:{match.group(1)}>"
    variable_name = rule.get("variable")
    if variable_name not in variables:
        raise NormalizationError(f"{path}: missing normalizer variable {variable_name!r}")
    expected = variables[variable_name]
    marker = f"<variable:{variable_name}>"
    if kind == "variable":
        if type(value) is not type(expected) or value != expected:
            raise NormalizationError(f"{path}: value does not equal variable {variable_name!r}")
        return marker
    raise NormalizationError(f"{path}: unsupported normalizer {kind!r}")


def first_difference(left: Any, right: Any, *, path: str = "$") -> Difference | None:
    if type(left) is not type(right):
        return Difference(path, left, right, "type")
    if isinstance(left, dict):
        left_keys = set(left)
        right_keys = set(right)
        if left_keys != right_keys:
            return Difference(path, sorted(left_keys), sorted(right_keys), "keys")
        for key in sorted(left_keys):
            difference = first_difference(left[key], right[key], path=f"{path}.{key}")
            if difference is not None:
                return difference
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return Difference(path, len(left), len(right), "length")
        for index, (left_item, right_item) in enumerate(zip(left, right, strict=True)):
            difference = first_difference(left_item, right_item, path=f"{path}[{index}]")
            if difference is not None:
                return difference
        return None
    if left != right:
        return Difference(path, left, right, "value")
    return None
