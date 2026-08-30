"""Strict JSON loading for reviewed conformance evidence."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


class StrictJsonError(ValueError):
    pass


def loads(text: str) -> Any:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        output: dict[str, Any] = {}
        for key, value in pairs:
            if key in output:
                raise StrictJsonError(f"duplicate JSON object key {key!r}")
            output[key] = value
        return output

    def reject_constant(value: str) -> None:
        raise StrictJsonError(f"non-standard JSON constant {value!r}")

    def finite_float(value: str) -> float:
        parsed = float(value)
        if not math.isfinite(parsed):
            raise StrictJsonError(f"non-finite JSON number {value!r}")
        return parsed

    try:
        return json.loads(
            text,
            object_pairs_hook=object_pairs,
            parse_constant=reject_constant,
            parse_float=finite_float,
        )
    except json.JSONDecodeError as exc:
        raise StrictJsonError(str(exc)) from exc


def load_path(path: str | Path) -> Any:
    return loads(Path(path).read_text(encoding="utf-8"))
