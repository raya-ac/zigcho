#!/usr/bin/env python3
"""Deterministic Stable protocol and legacy web surface inventory."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from strict_json import load_path


WEB_ROUTE = re.compile(r"/web/[A-Za-z0-9._~!$&()*+,;=:@%/-]+\.php\Z")
METHOD = re.compile(r"req\.head\.method\s*==\s*\.([A-Za-z_][A-Za-z0-9_]*)")


class InspectionError(RuntimeError):
    pass


@dataclass(frozen=True)
class ZigString:
    value: str
    offset: int
    line: int


@dataclass(frozen=True)
class SourcePacket:
    name: str
    packet_id: int


@dataclass(frozen=True)
class SourceRoute:
    path: str
    methods: tuple[str, ...]
    source: str
    line: int


def _mask_non_code(source: str) -> str:
    """Mask Zig comments and literals while preserving positions and newlines."""
    chars = list(source)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(chars):
        char = chars[index]
        next_char = chars[index + 1] if index + 1 < len(chars) else ""
        if state == "code":
            if char == "/" and next_char == "/":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "line_comment"
                continue
            if char == "/" and next_char == "*":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "block_comment"
                block_depth = 1
                continue
            if char == '"':
                chars[index] = " "
                index += 1
                state = "string"
                continue
            if char == "'":
                chars[index] = " "
                index += 1
                state = "character"
                continue
            index += 1
            continue
        if state == "line_comment":
            if char == "\n":
                state = "code"
            else:
                chars[index] = " "
            index += 1
            continue
        if state == "block_comment":
            if char == "/" and next_char == "*":
                chars[index] = chars[index + 1] = " "
                block_depth += 1
                index += 2
                continue
            if char == "*" and next_char == "/":
                chars[index] = chars[index + 1] = " "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
                continue
            if char != "\n":
                chars[index] = " "
            index += 1
            continue
        if state in {"string", "character"}:
            delimiter = '"' if state == "string" else "'"
            if char == "\\":
                chars[index] = " "
                if index + 1 < len(chars):
                    if chars[index + 1] != "\n":
                        chars[index + 1] = " "
                    index += 2
                else:
                    index += 1
                continue
            if char == delimiter:
                chars[index] = " "
                index += 1
                state = "code"
                continue
            if char != "\n":
                chars[index] = " "
            index += 1
            continue
    return "".join(chars)


def _zig_strings(source: str, start: int = 0, end: int | None = None) -> list[ZigString]:
    """Return ordinary Zig string literals outside comments and character literals."""
    limit = len(source) if end is None else end
    result: list[ZigString] = []
    index = start
    state = "code"
    block_depth = 0
    while index < limit:
        char = source[index]
        next_char = source[index + 1] if index + 1 < limit else ""
        if state == "code":
            if char == "/" and next_char == "/":
                index += 2
                state = "line_comment"
                continue
            if char == "/" and next_char == "*":
                index += 2
                state = "block_comment"
                block_depth = 1
                continue
            if char == "'":
                index += 1
                state = "character"
                continue
            if char != '"':
                index += 1
                continue
            literal_offset = index
            index += 1
            value: list[str] = []
            while index < limit:
                current = source[index]
                if current == '"':
                    result.append(ZigString("".join(value), literal_offset, source.count("\n", 0, literal_offset) + 1))
                    index += 1
                    break
                if current == "\\":
                    if index + 1 >= limit:
                        raise InspectionError("unterminated Zig string escape")
                    escaped = source[index + 1]
                    escapes = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "'": "'", "0": "\0"}
                    if escaped not in escapes:
                        raise InspectionError(f"unsupported Zig string escape \\{escaped}")
                    value.append(escapes[escaped])
                    index += 2
                    continue
                if current == "\n":
                    raise InspectionError("unterminated Zig string literal")
                value.append(current)
                index += 1
            else:
                raise InspectionError("unterminated Zig string literal")
            continue
        if state == "line_comment":
            if char == "\n":
                state = "code"
            index += 1
            continue
        if state == "block_comment":
            if char == "/" and next_char == "*":
                block_depth += 1
                index += 2
                continue
            if char == "*" and next_char == "/":
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
                continue
            index += 1
            continue
        if state == "character":
            if char == "\\":
                index += 2
            elif char == "'":
                index += 1
                state = "code"
            else:
                index += 1
    return result


def _matching(masked: str, opening: int, open_char: str, close_char: str) -> int:
    if opening >= len(masked) or masked[opening] != open_char:
        raise InspectionError(f"expected {open_char!r} at offset {opening}")
    depth = 0
    for index in range(opening, len(masked)):
        char = masked[index]
        if char == open_char:
            depth += 1
        elif char == close_char:
            depth -= 1
            if depth == 0:
                return index
    raise InspectionError(f"unclosed {open_char!r} at offset {opening}")


def _function_body(source: str, function: str) -> tuple[int, int, str]:
    masked = _mask_non_code(source)
    match = re.search(rf"\bfn\s+{re.escape(function)}\s*\(", masked)
    if match is None:
        raise InspectionError(f"function {function!r} was not found")
    body_start = masked.find("{", match.end())
    if body_start < 0:
        raise InspectionError(f"function {function!r} has no body")
    body_end = _matching(masked, body_start, "{", "}")
    return body_start, body_end, masked


def parse_client_packets(source: str, enum_name: str = "ClientPacket") -> list[SourcePacket]:
    masked = _mask_non_code(source)
    match = re.search(rf"\bpub\s+const\s+{re.escape(enum_name)}\s*=\s*enum\s*\(\s*u16\s*\)\s*\{{", masked)
    if match is None:
        raise InspectionError(f"enum {enum_name!r} was not found")
    body_start = masked.find("{", match.start())
    body_end = _matching(masked, body_start, "{", "}")
    entries: list[SourcePacket] = []
    for raw_entry in masked[body_start + 1 : body_end].split(","):
        entry = raw_entry.strip()
        if not entry or entry == "_":
            continue
        parsed = re.fullmatch(r"([a-z_][a-z0-9_]*)\s*=\s*([0-9]+)", entry)
        if parsed is None:
            raise InspectionError(f"unsupported {enum_name} entry: {entry!r}")
        entries.append(SourcePacket(parsed.group(1), int(parsed.group(2))))
    return entries


def parse_poll_handlers(source: str, function: str = "pollLocked") -> list[str]:
    body_start, body_end, masked = _function_body(source, function)
    loop = re.search(r"\bwhile\s*\(\s*try\s+reader\.next\s*\(\s*\)\s*\)", masked[body_start:body_end])
    if loop is None:
        raise InspectionError(f"packet reader loop was not found in {function!r}")
    switch_start = masked.find("switch", body_start + loop.end(), body_end)
    if switch_start < 0:
        raise InspectionError(f"packet switch was not found in {function!r}")
    expression_start = masked.find("(", switch_start, body_end)
    expression_end = _matching(masked, expression_start, "(", ")")
    switch_body = masked.find("{", expression_end, body_end)
    if switch_body < 0:
        raise InspectionError(f"packet switch body was not found in {function!r}")
    switch_end = _matching(masked, switch_body, "{", "}")

    handlers: list[str] = []
    arm_start = switch_body + 1
    index = arm_start
    parens = brackets = braces = 0
    arrow: int | None = None
    while index < switch_end:
        char = masked[index]
        if char == "(":
            parens += 1
        elif char == ")":
            parens -= 1
        elif char == "[":
            brackets += 1
        elif char == "]":
            brackets -= 1
        elif char == "{":
            braces += 1
        elif char == "}":
            braces -= 1
        if parens == brackets == braces == 0:
            if arrow is None and masked.startswith("=>", index):
                arrow = index
                index += 2
                continue
            if arrow is not None and char == ",":
                label = masked[arm_start:arrow]
                handlers.extend(re.findall(r"\.([a-z_][a-z0-9_]*)", label))
                arm_start = index + 1
                arrow = None
        index += 1
    if arrow is not None:
        raise InspectionError(f"unterminated packet switch arm in {function!r}")
    return handlers


def parse_restricted_allowlist(source: str, function: str = "restrictedClientPacketAllowed") -> list[str]:
    body_start, body_end, masked = _function_body(source, function)
    switch_start = masked.find("switch", body_start, body_end)
    if switch_start < 0:
        raise InspectionError(f"switch was not found in {function!r}")
    expression_start = masked.find("(", switch_start, body_end)
    expression_end = _matching(masked, expression_start, "(", ")")
    if masked[body_start + 1 : switch_start].strip() != "return" or masked[expression_start + 1 : expression_end].strip() != "packet":
        raise InspectionError(f"{function!r} must directly return switch(packet)")
    switch_body = masked.find("{", expression_end, body_end)
    if switch_body < 0:
        raise InspectionError(f"switch body was not found in {function!r}")
    switch_end = _matching(masked, switch_body, "{", "}")
    if masked[switch_end + 1 : body_end].strip() != ";":
        raise InspectionError(f"{function!r} cannot contain logic outside its packet switch")

    allowed: list[str] = []
    saw_else_false = False
    arm_start = switch_body + 1
    arrow: int | None = None
    parens = brackets = braces = 0
    index = arm_start
    while index < switch_end:
        char = masked[index]
        if char == "(":
            parens += 1
        elif char == ")":
            parens -= 1
        elif char == "[":
            brackets += 1
        elif char == "]":
            brackets -= 1
        elif char == "{":
            braces += 1
        elif char == "}":
            braces -= 1
        if parens == brackets == braces == 0:
            if arrow is None and masked.startswith("=>", index):
                arrow = index
                index += 2
                continue
            if arrow is not None and char == ",":
                expression = masked[arrow + 2 : index].strip()
                label = masked[arm_start:arrow].strip()
                if expression == "true":
                    names = re.findall(r"\.([a-z_][a-z0-9_]*)", label)
                    if not names or "else" in label:
                        raise InspectionError(f"{function!r} has an invalid true switch arm")
                    allowed.extend(names)
                elif expression == "false" and label == "else":
                    saw_else_false = True
                else:
                    raise InspectionError(f"{function!r} has a non-boolean or unclassified switch arm")
                arm_start = index + 1
                arrow = None
        index += 1
    if arrow is not None:
        raise InspectionError(f"unterminated restricted switch arm in {function!r}")
    if not saw_else_false:
        raise InspectionError(f"{function!r} must deny every unlisted packet")
    return allowed


def has_restricted_dispatch_guard(
    source: str,
    *,
    function: str = "pollLocked",
    guard_function: str = "restrictedClientPacketAllowed",
) -> bool:
    body_start, body_end, masked = _function_body(source, function)
    loop = re.search(r"\bwhile\s*\(\s*try\s+reader\.next\s*\(\s*\)\s*\)", masked[body_start:body_end])
    if loop is None:
        return False
    switch_start = masked.find("switch", body_start + loop.end(), body_end)
    if switch_start < 0:
        return False
    expression_start = masked.find("(", switch_start, body_end)
    if expression_start < 0:
        return False
    expression_end = _matching(masked, expression_start, "(", ")")
    expression = masked[expression_start + 1 : expression_end]
    switch_body = masked.find("{", expression_end, body_end)
    if switch_body < 0:
        return False
    switch_end = _matching(masked, switch_body, "{", "}")
    pattern = re.compile(
        rf"^\s*if\s*\(\s*session\.user\.restricted\s+and\s+!\s*"
        rf"protocol\.{re.escape(guard_function)}\s*\(\s*packet\.id\s*\)\s*\)\s*"
        rf"@as\s*\(\s*protocol\.ClientPacket\s*,\s*@enumFromInt\s*\(\s*"
        rf"std\.math\.maxInt\s*\(\s*u16\s*\)\s*\)\s*\)\s*else\s+packet\.id\s*$"
    )
    if pattern.fullmatch(expression) is None:
        return False

    arm_start = switch_body + 1
    arrow: int | None = None
    parens = brackets = braces = 0
    index = arm_start
    saw_noop_else = False
    while index < switch_end:
        char = masked[index]
        if char == "(":
            parens += 1
        elif char == ")":
            parens -= 1
        elif char == "[":
            brackets += 1
        elif char == "]":
            brackets -= 1
        elif char == "{":
            braces += 1
        elif char == "}":
            braces -= 1
        if parens == brackets == braces == 0:
            if arrow is None and masked.startswith("=>", index):
                arrow = index
                index += 2
                continue
            if arrow is not None and char == ",":
                label = masked[arm_start:arrow].strip()
                arm = masked[arrow + 2 : index].strip()
                if label == "else":
                    if arm not in {"{}", "continue"}:
                        return False
                    saw_noop_else = True
                arm_start = index + 1
                arrow = None
        index += 1
    return arrow is None and saw_noop_else


def has_restricted_capture_guard(
    source: str,
    *,
    function: str = "captureStablePollLocked",
    guard_function: str = "restrictedClientPacketAllowed",
) -> bool:
    body_start, body_end, masked = _function_body(source, function)
    loop = re.search(r"\bwhile\s*\(\s*try\s+packets\.next\s*\(\s*\)\s*\)\s*\|packet\|", masked[body_start:body_end])
    if loop is None:
        return False
    loop_start = body_start + loop.end()
    loop_body = masked.find("{", loop_start, body_end)
    if loop_body < 0:
        return False
    switch_start = masked.find("switch", loop_body, body_end)
    if switch_start < 0:
        return False
    prefix = masked[loop_body + 1 : switch_start]
    pattern = re.compile(
        rf"^\s*if\s*\(\s*session\.user\.restricted\s+and\s+!\s*"
        rf"protocol\.{re.escape(guard_function)}\s*\(\s*packet\.id\s*\)\s*\)\s*continue\s*;\s*$"
    )
    return pattern.fullmatch(prefix) is not None


def has_restricted_presence_preparation_guard(
    source: str,
    *,
    function: str = "prepareLazerPresences",
) -> bool:
    body_start, body_end, masked = _function_body(source, function)
    reader_start = masked.find("var reader", body_start, body_end)
    if reader_start < 0:
        return False
    prefix = masked[body_start + 1 : reader_start]
    return re.search(r"\bif\s*\(\s*restricted\s*\)\s*return\s+prepared\s*;", prefix) is not None


def _top_level_dispatch_conditions(source: str) -> Iterable[tuple[int, int]]:
    body_start, body_end, masked = _function_body(source, "dispatch")
    index = body_start + 1
    brace_depth = 0
    while index < body_end:
        char = masked[index]
        if char == "{":
            brace_depth += 1
            index += 1
            continue
        if char == "}":
            brace_depth -= 1
            index += 1
            continue
        if brace_depth == 0 and masked.startswith("if", index):
            before = masked[index - 1] if index > body_start + 1 else " "
            after = masked[index + 2] if index + 2 < body_end else " "
            if not (before.isalnum() or before == "_") and not (after.isalnum() or after == "_"):
                condition_start = index + 2
                while condition_start < body_end and masked[condition_start].isspace():
                    condition_start += 1
                if condition_start < body_end and masked[condition_start] == "(":
                    condition_end = _matching(masked, condition_start, "(", ")")
                    yield condition_start + 1, condition_end
                    index = condition_end + 1
                    continue
        index += 1


def discover_routes(root: Path, globs: list[str]) -> tuple[list[SourceRoute], dict[str, list[str]]]:
    files: set[Path] = set()
    for pattern in globs:
        files.update(path for path in root.glob(pattern) if path.is_file())
    registrations: list[SourceRoute] = []
    all_literals: dict[str, list[str]] = defaultdict(list)
    for path in sorted(files):
        relative = path.relative_to(root).as_posix()
        source = path.read_text(encoding="utf-8")
        route_literals = [literal for literal in _zig_strings(source) if WEB_ROUTE.fullmatch(literal.value)]
        if not route_literals:
            continue
        for literal in route_literals:
            all_literals[literal.value].append(relative)
        for condition_start, condition_end in _top_level_dispatch_conditions(source):
            condition = source[condition_start:condition_end]
            methods = tuple(sorted({match.group(1).upper() for match in METHOD.finditer(condition)})) or ("ANY",)
            for literal in _zig_strings(source, condition_start, condition_end):
                if WEB_ROUTE.fullmatch(literal.value):
                    registrations.append(SourceRoute(literal.value, methods, relative, literal.line))
    return registrations, {key: sorted(set(value)) for key, value in sorted(all_literals.items())}


def _error(code: str, subject: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message, "subject": subject}


def _duplicates(values: Iterable[Any]) -> list[Any]:
    counts = Counter(values)
    return sorted(value for value, count in counts.items() if count > 1)


def inspect(root: Path, manifest_path: Path) -> dict[str, Any]:
    manifest = load_path(manifest_path)
    errors: list[dict[str, str]] = []

    packet_config = manifest["packet_inventory"]
    protocol_source = root / packet_config["enum_source"]
    handler_source = root / packet_config["handler_source"]
    source_packets = parse_client_packets(protocol_source.read_text(encoding="utf-8"), packet_config["enum"])
    source_handlers = parse_poll_handlers(handler_source.read_text(encoding="utf-8"), packet_config["handler_function"])
    manifest_packets = manifest["packets"]

    for name in _duplicates(packet.name for packet in source_packets):
        errors.append(_error("duplicate_source_packet_name", name, f"ClientPacket name {name!r} is declared more than once"))
    for packet_id in _duplicates(packet.packet_id for packet in source_packets):
        errors.append(_error("duplicate_source_packet_id", str(packet_id), f"ClientPacket id {packet_id} is declared more than once"))
    for name in _duplicates(source_handlers):
        errors.append(_error("duplicate_packet_handler", name, f"packet {name!r} has more than one top-level poll handler"))
    for name in _duplicates(packet["name"] for packet in manifest_packets):
        errors.append(_error("duplicate_manifest_packet_name", name, f"manifest packet name {name!r} is duplicated"))
    for packet_id in _duplicates(packet["id"] for packet in manifest_packets):
        errors.append(_error("duplicate_manifest_packet_id", str(packet_id), f"manifest packet id {packet_id} is duplicated"))

    source_by_name = {packet.name: packet for packet in source_packets}
    manifest_by_name = {packet["name"]: packet for packet in manifest_packets}
    handler_set = set(source_handlers)
    source_names = set(source_by_name)
    manifest_names = set(manifest_by_name)
    for name in sorted(source_names - manifest_names):
        errors.append(_error("unclassified_source_packet", name, f"source packet {name!r} is not classified in the manifest"))
    for name in sorted(manifest_names - source_names):
        errors.append(_error("missing_source_packet", name, f"manifest packet {name!r} no longer exists in ClientPacket"))
    for name in sorted(handler_set - source_names):
        errors.append(_error("handler_for_undeclared_packet", name, f"poll handler {name!r} is not declared by ClientPacket"))
    for name in sorted(source_names & manifest_names):
        source_packet = source_by_name[name]
        expected = manifest_by_name[name]
        if source_packet.packet_id != expected["id"]:
            errors.append(_error("packet_id_changed", name, f"packet {name!r} is id {source_packet.packet_id}, expected {expected['id']}"))
        classification = expected["classification"]
        if classification == "handled" and name not in handler_set:
            errors.append(_error("missing_packet_handler", name, f"handled packet {name!r} is not explicit in the poll switch"))
        elif classification == "ignored_compat" and name in handler_set:
            errors.append(_error("ignored_packet_is_handled", name, f"ignored compatibility packet {name!r} now has a poll handler"))
        elif classification not in {"handled", "ignored_compat"}:
            errors.append(_error("invalid_packet_classification", name, f"packet {name!r} has unknown classification {classification!r}"))

    restricted_config = manifest.get("restricted_dispatch")
    restricted_report = None
    if restricted_config is not None:
        restricted_source = root / restricted_config["source"]
        allowed_names = parse_restricted_allowlist(
            restricted_source.read_text(encoding="utf-8"),
            restricted_config["function"],
        )
        for name in _duplicates(allowed_names):
            errors.append(_error("duplicate_restricted_allowlist_packet", name, f"restricted packet {name!r} is listed more than once"))
        unknown_allowed = sorted(set(allowed_names) - source_names)
        for name in unknown_allowed:
            errors.append(_error("unknown_restricted_allowlist_packet", name, f"restricted allowlist packet {name!r} is not a ClientPacket"))
        actual_ids = sorted(source_by_name[name].packet_id for name in set(allowed_names) & source_names)
        expected_ids = sorted(restricted_config["zigcho_allowed_packet_ids"])
        if actual_ids != expected_ids:
            errors.append(
                _error(
                    "restricted_allowlist_changed",
                    restricted_config["function"],
                    f"restricted allowlist is {actual_ids}, expected {expected_ids}",
                )
            )
        if not has_restricted_dispatch_guard(
            handler_source.read_text(encoding="utf-8"),
            function=packet_config["handler_function"],
            guard_function=restricted_config["function"],
        ):
            errors.append(
                _error(
                    "missing_restricted_dispatch_guard",
                    packet_config["handler_function"],
                    "the Stable packet switch no longer applies the restricted allowlist before dispatch",
                )
            )
        pre_dispatch = restricted_config.get("pre_dispatch_guards", {})
        capture_function = pre_dispatch.get("capture_function")
        if not isinstance(capture_function, str) or not has_restricted_capture_guard(
            handler_source.read_text(encoding="utf-8"),
            function=capture_function or "captureStablePollLocked",
            guard_function=restricted_config["function"],
        ):
            errors.append(
                _error(
                    "missing_restricted_capture_guard",
                    str(capture_function),
                    "the pre-dispatch Stable capture pass no longer skips denied restricted packets",
                )
            )
        presence_function = pre_dispatch.get("presence_function")
        if not isinstance(presence_function, str) or not has_restricted_presence_preparation_guard(
            handler_source.read_text(encoding="utf-8"),
            function=presence_function or "prepareLazerPresences",
        ):
            errors.append(
                _error(
                    "missing_restricted_presence_guard",
                    str(presence_function),
                    "the pre-dispatch lazer presence pass no longer returns before restricted packet traversal",
                )
            )
        registered_ids = sorted(packet["id"] for packet in manifest_packets if packet["classification"] == "handled")
        zigcho_denied = sorted(restricted_config["zigcho_denied_packet_ids"])
        reference_allowed = sorted(restricted_config["reference_allowed_packet_ids"])
        reference_denied = sorted(restricted_config["reference_denied_packet_ids"])
        for label, allowed, denied in (
            ("zigcho", expected_ids, zigcho_denied),
            ("reference", reference_allowed, reference_denied),
        ):
            if set(allowed) & set(denied) or sorted(set(allowed) | set(denied)) != registered_ids:
                errors.append(
                    _error(
                        "restricted_dispatch_incomplete",
                        label,
                        f"{label} restricted allow/deny sets must partition all handled packet ids",
                    )
                )
        restricted_report = {
            "classified_packet_ids": registered_ids,
            "reference_allowed_packet_ids": reference_allowed,
            "zigcho_allowed_packet_ids": actual_ids,
        }

    route_config = manifest["route_inventory"]
    source_routes, all_route_literals = discover_routes(root, route_config["source_globs"])
    manifest_routes = manifest["routes"]
    for path in _duplicates(route["path"] for route in manifest_routes):
        errors.append(_error("duplicate_manifest_route", path, f"manifest route {path!r} is duplicated"))
    registration_counts = Counter(route.path for route in source_routes)
    for path, count in sorted(registration_counts.items()):
        if count > 1:
            sites = sorted(f"{route.source}:{route.line}" for route in source_routes if route.path == path)
            errors.append(_error("duplicate_source_route", path, f"route {path!r} has {count} top-level registrations: {', '.join(sites)}"))

    source_route_by_path = {route.path: route for route in source_routes}
    manifest_route_by_path = {route["path"]: route for route in manifest_routes}
    source_paths = set(source_route_by_path)
    manifest_paths = set(manifest_route_by_path)
    literal_paths = set(all_route_literals)
    for path in sorted(literal_paths - source_paths):
        errors.append(_error("unregistered_route_literal", path, f"legacy route literal {path!r} is not in a top-level dispatch guard"))
    for path in sorted(source_paths - manifest_paths):
        errors.append(_error("unclassified_source_route", path, f"source route {path!r} is not classified in the manifest"))
    for path in sorted(manifest_paths - source_paths):
        errors.append(_error("missing_source_route", path, f"manifest route {path!r} no longer has a top-level dispatch guard"))
    for path in sorted(source_paths & manifest_paths):
        source_route = source_route_by_path[path]
        expected = manifest_route_by_path[path]
        expected_methods = tuple(sorted(expected["methods"]))
        if source_route.methods != expected_methods:
            errors.append(_error("route_methods_changed", path, f"route {path!r} uses {list(source_route.methods)}, expected {list(expected_methods)}"))
        if source_route.source != expected["source"]:
            errors.append(_error("route_source_changed", path, f"route {path!r} is in {source_route.source!r}, expected {expected['source']!r}"))
        if expected["classification"] != "implemented":
            errors.append(_error("invalid_route_classification", path, f"route {path!r} has unknown classification {expected['classification']!r}"))

    packet_items = []
    for packet in sorted(source_packets, key=lambda item: (item.packet_id, item.name)):
        classified = manifest_by_name.get(packet.name)
        packet_items.append({
            "area": classified["area"] if classified else None,
            "classification": classified["classification"] if classified else None,
            "explicit_handler": packet.name in handler_set,
            "id": packet.packet_id,
            "name": packet.name,
        })
    route_items = []
    for route in sorted(source_routes, key=lambda item: item.path):
        classified = manifest_route_by_path.get(route.path)
        route_items.append({
            "area": classified["area"] if classified else None,
            "classification": classified["classification"] if classified else None,
            "line": route.line,
            "methods": list(route.methods),
            "path": route.path,
            "source": route.source,
        })

    errors.sort(key=lambda item: (item["code"], item["subject"], item["message"]))
    packet_unclassified = sorted(source_names - manifest_names)
    packet_missing = sorted(manifest_names - source_names)
    route_unclassified = sorted(source_paths - manifest_paths)
    route_missing = sorted(manifest_paths - source_paths)
    handled_count = sum(item["explicit_handler"] for item in packet_items)
    ignored_count = sum(item["classification"] == "ignored_compat" for item in packet_items)
    return {
        "bancho_client_packets": {
            "classified": len(source_names & manifest_names),
            "declared": len(source_packets),
            "explicitly_handled": handled_count,
            "gaps": {
                "missing_from_source": packet_missing,
                "unclassified": packet_unclassified,
            },
            "ignored_compatibility": ignored_count,
            "items": packet_items,
        },
        "errors": errors,
        "legacy_web_routes": {
            "classified": len(source_paths & manifest_paths),
            "gaps": {
                "missing_from_source": route_missing,
                "unclassified": route_unclassified,
                "unregistered_literals": sorted(literal_paths - source_paths),
            },
            "items": route_items,
            "registered": len(source_routes),
        },
        "restricted_dispatch": restricted_report,
        "schema_version": 1,
        "status": "ok" if not errors else "failed",
    }


def check_coverage(repo_root: str | Path, manifest_path: str | Path | None = None) -> dict[str, Any]:
    """Importable API used by CI aggregators and focused unit tests."""
    root = Path(repo_root).resolve()
    checked_manifest = Path(manifest_path).resolve() if manifest_path is not None else Path(__file__).with_name("manifest.json").resolve()
    return inspect(root, checked_manifest)


def build_manifest(
    repo_root: str | Path,
    reference_root: str | Path | None = None,
    manifest_path: str | Path | None = None,
) -> dict[str, Any]:
    """Return the checked Zigcho-side surface in an aggregator-friendly shape.

    ``reference_root`` is accepted so the top-level conformance runner can use
    one provider interface. This provider deliberately inspects Zigcho only.
    """
    del reference_root
    report = check_coverage(repo_root, manifest_path)
    return {
        "errors": report["errors"],
        "packets": report.get("bancho_client_packets", {}).get("items", []),
        "routes": report.get("legacy_web_routes", {}).get("items", []),
        "schema_version": 1,
        "status": report["status"],
    }


def _parse_args(argv: list[str]) -> argparse.Namespace:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=default_root, help="repository root")
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("manifest.json"), help="checked classification manifest")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        report = check_coverage(args.root, args.manifest)
    except (InspectionError, KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        report = {
            "errors": [_error("inspection_failed", "inventory", str(error))],
            "schema_version": 1,
            "status": "failed",
        }
    sys.stdout.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
