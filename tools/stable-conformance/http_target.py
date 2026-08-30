"""Bounded, stateful HTTP adapter for one conformance target."""

from __future__ import annotations

import queue
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.cookiejar import CookieJar
from typing import Any, Mapping

from transcript import TranscriptError, encode_body, encode_query, render_value


class TransportError(RuntimeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


@dataclass(frozen=True)
class HttpResponse:
    status: int
    reason: str
    headers: dict[str, list[str]]
    body: bytes
    elapsed_ms: float

    def header(self, name: str) -> str | None:
        values = self.headers.get(name.lower())
        return values[-1] if values else None

    @property
    def content_type(self) -> str:
        value = self.header("content-type") or ""
        return value.split(";", 1)[0].strip().lower()


@dataclass(frozen=True)
class PreparedRequest:
    method: str
    path: str
    query: str
    body: bytes | None
    headers: dict[str, str]


def prepare_request(request_spec: Mapping[str, Any], variables: Mapping[str, Any]) -> PreparedRequest:
    method = render_value(request_spec.get("method"), variables)
    path = render_value(request_spec.get("path"), variables)
    if not isinstance(method, str) or not method or method != method.upper():
        raise TranscriptError("rendered request method must be uppercase text")
    if not isinstance(path, str) or not path.startswith("/") or path.startswith("//") or "://" in path:
        raise TranscriptError("rendered request path escaped the configured origin")
    parsed_path = urllib.parse.urlsplit(path)
    if parsed_path.scheme or parsed_path.netloc or parsed_path.fragment:
        raise TranscriptError("rendered request path escaped the configured origin")
    query = encode_query(request_spec.get("query"), variables)
    body = encode_body(request_spec.get("body"), variables)
    raw_headers = render_value(request_spec.get("headers", {}), variables)
    if not isinstance(raw_headers, dict) or not all(
        isinstance(key, str)
        and key
        and isinstance(value, (str, int, float, bool))
        for key, value in raw_headers.items()
    ):
        raise TranscriptError("rendered request headers must be a scalar object")
    headers = {key: str(value) for key, value in raw_headers.items()}
    forbidden_headers = {
        "connection",
        "content-length",
        "cookie",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
    forbidden = sorted(key for key in headers if key.lower() in forbidden_headers)
    if forbidden:
        raise TranscriptError(f"request cannot override transport header {forbidden[0]!r}")
    _set_default_content_type(headers, request_spec.get("body"))
    return PreparedRequest(method=method, path=path, query=query, body=body, headers=headers)


class TargetClient:
    def __init__(
        self,
        *,
        name: str,
        origin: str,
        timeout_seconds: float = 10.0,
        max_response_bytes: int = 16 * 1024 * 1024,
    ) -> None:
        parsed = urllib.parse.urlsplit(origin)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError(f"{name}: origin must be an absolute http(s) URL")
        if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
            raise ValueError(f"{name}: origin cannot include credentials, a path, query, or fragment")
        if timeout_seconds <= 0 or max_response_bytes <= 0:
            raise ValueError(f"{name}: timeout and response limit must be positive")
        self.name = name
        self.origin = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))
        self.timeout_seconds = timeout_seconds
        self.max_response_bytes = max_response_bytes
        self._poisoned = False
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(CookieJar()),
            _NoRedirect(),
        )

    def request(self, request_spec: Mapping[str, Any], variables: Mapping[str, Any]) -> HttpResponse:
        if self._poisoned:
            raise TransportError(f"{self.name}: transport is unusable after a wall-deadline timeout")
        results: queue.Queue[HttpResponse | Exception] = queue.Queue(maxsize=1)

        def perform() -> None:
            try:
                results.put_nowait(self._request_blocking(request_spec, variables))
            except Exception as exc:  # The caller receives a bounded, sanitized transport error.
                results.put_nowait(exc)

        worker = threading.Thread(target=perform, name=f"stable-conformance-{self.name}", daemon=True)
        worker.start()
        try:
            result = results.get(timeout=self.timeout_seconds)
        except queue.Empty as exc:
            self._poisoned = True
            raise TransportError(
                f"{self.name}: request exceeded the {self.timeout_seconds:g}s wall deadline"
            ) from exc
        if isinstance(result, Exception):
            if isinstance(result, (TransportError, TranscriptError)):
                raise result
            raise TransportError(f"{self.name}: {type(result).__name__}: {result}") from result
        return result

    def _request_blocking(self, request_spec: Mapping[str, Any], variables: Mapping[str, Any]) -> HttpResponse:
        prepared = prepare_request(request_spec, variables)
        url = self.origin + prepared.path + (
            ("&" if "?" in prepared.path else "?") + prepared.query if prepared.query else ""
        )
        request = urllib.request.Request(
            url,
            data=prepared.body,
            headers=prepared.headers,
            method=prepared.method,
        )
        started = time.monotonic()
        try:
            response = self._opener.open(request, timeout=self.timeout_seconds)
        except urllib.error.HTTPError as exc:
            response = exc
        except (OSError, urllib.error.URLError, TimeoutError) as exc:
            raise TransportError(f"{self.name}: {type(exc).__name__}: {exc}") from exc
        try:
            payload = response.read(self.max_response_bytes + 1)
            if len(payload) > self.max_response_bytes:
                raise TransportError(
                    f"{self.name}: response exceeded {self.max_response_bytes} bytes"
                )
            headers_out: dict[str, list[str]] = {}
            for key in response.headers.keys():
                headers_out[key.lower()] = response.headers.get_all(key) or []
            return HttpResponse(
                status=response.status,
                reason=str(response.reason),
                headers=headers_out,
                body=payload,
                elapsed_ms=(time.monotonic() - started) * 1000,
            )
        finally:
            response.close()


def _set_default_content_type(headers: dict[str, str], body_spec: Any) -> None:
    if body_spec is None or any(key.lower() == "content-type" for key in headers):
        return
    encoding = body_spec.get("encoding") if isinstance(body_spec, dict) else None
    if encoding == "json":
        headers["Content-Type"] = "application/json"
    elif encoding == "form":
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    else:
        headers["Content-Type"] = "application/octet-stream"
