"""Unified LLM provider.

Light wrapper around the ``openai`` and ``anthropic`` Python SDKs that exposes
a single :class:`LLM` class with AI-Gateway-style model strings. We do not
hard-import either SDK at module load time so the SDK stays usable when
neither dependency is installed.

Provider routing rules:

  * ``"<model>"`` (no slash) — defaults to OpenAI
  * ``"openai/<model>"`` — OpenAI
  * ``"anthropic/<model>"`` — Anthropic
  * ``"gateway/<provider>/<model>"`` — Vercel AI Gateway routing (uses
    ``AI_GATEWAY_API_KEY`` and ``AI_GATEWAY_BASE_URL``)

If the matching API key isn't set, :class:`LLM` raises
:class:`LLMUnavailableError` on construction. Callers should catch this and
either fall back to scripted behavior or surface a helpful message.

This is intentionally minimal — just ``complete()`` and ``complete_with_tools``.
The Vercel-style "tool loop" lives in :mod:`among_them_sdk.cognition.tools`.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Any, Literal, Protocol

logger = logging.getLogger("among_them_sdk.cognition.llm")


class LLMUnavailableError(RuntimeError):
    """Raised when the requested provider lacks credentials or is unsupported."""


@dataclass
class LLMResponse:
    text: str
    model: str
    raw: dict[str, Any] | None = None
    tool_calls: list[dict[str, Any]] | None = None


class LLMProvider(Protocol):
    def complete(
        self,
        system: str,
        user: str,
        *,
        response_format: Literal["text", "json"] = "text",
        max_tokens: int = 1024,
        temperature: float = 0.7,
    ) -> LLMResponse: ...


def _split_model(model: str) -> tuple[str, str]:
    if "/" not in model:
        return ("openai", model)
    head, tail = model.split("/", 1)
    head = head.lower()
    if head in {"openai", "anthropic"}:
        return (head, tail)
    if head == "gateway":
        return ("gateway", tail)
    return ("openai", model)


class _OpenAIBackend:
    def __init__(self, model: str, api_key: str, base_url: str | None = None):
        try:
            from openai import OpenAI  # type: ignore[import-not-found]
        except ImportError as exc:
            raise LLMUnavailableError(
                "OpenAI provider requires `pip install openai`"
            ) from exc
        kwargs: dict[str, Any] = {"api_key": api_key}
        if base_url:
            kwargs["base_url"] = base_url
        self._client = OpenAI(**kwargs)
        self.model = model

    def complete(
        self,
        system: str,
        user: str,
        *,
        response_format: Literal["text", "json"] = "text",
        max_tokens: int = 1024,
        temperature: float = 0.7,
    ) -> LLMResponse:
        kwargs: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
        }
        if response_format == "json":
            kwargs["response_format"] = {"type": "json_object"}
        try:
            resp = self._client.chat.completions.create(**kwargs)
        except Exception as exc:
            raise LLMUnavailableError(f"OpenAI completion failed: {exc}") from exc
        text = resp.choices[0].message.content or ""
        return LLMResponse(text=text, model=self.model, raw=resp.model_dump() if hasattr(resp, "model_dump") else None)


class _AnthropicBackend:
    def __init__(self, model: str, api_key: str):
        try:
            from anthropic import Anthropic  # type: ignore[import-not-found]
        except ImportError as exc:
            raise LLMUnavailableError(
                "Anthropic provider requires `pip install anthropic`"
            ) from exc
        self._client = Anthropic(api_key=api_key)
        self.model = model

    def complete(
        self,
        system: str,
        user: str,
        *,
        response_format: Literal["text", "json"] = "text",
        max_tokens: int = 1024,
        temperature: float = 0.7,
    ) -> LLMResponse:
        if response_format == "json":
            user = user + "\n\nRespond with valid JSON only, no surrounding prose."
        try:
            resp = self._client.messages.create(
                model=self.model,
                system=system,
                messages=[{"role": "user", "content": user}],
                max_tokens=max_tokens,
                temperature=temperature,
            )
        except Exception as exc:
            raise LLMUnavailableError(f"Anthropic completion failed: {exc}") from exc
        text = "".join(block.text for block in resp.content if hasattr(block, "text"))
        return LLMResponse(text=text, model=self.model)


class LLM:
    """Unified entry point: ``LLM("gpt-5.5")`` or ``LLM("anthropic/claude-...")``."""

    def __init__(self, model: str = "gpt-5.5"):
        provider_kind, real_model = _split_model(model)
        self.model_string = model
        self.provider_kind = provider_kind

        if provider_kind == "openai":
            api_key = os.environ.get("OPENAI_API_KEY")
            if not api_key:
                raise LLMUnavailableError("OPENAI_API_KEY is not set")
            self._backend: LLMProvider = _OpenAIBackend(real_model, api_key)
        elif provider_kind == "anthropic":
            api_key = os.environ.get("ANTHROPIC_API_KEY")
            if not api_key:
                raise LLMUnavailableError("ANTHROPIC_API_KEY is not set")
            self._backend = _AnthropicBackend(real_model, api_key)
        elif provider_kind == "gateway":
            api_key = os.environ.get("AI_GATEWAY_API_KEY")
            base_url = os.environ.get("AI_GATEWAY_BASE_URL", "https://ai-gateway.vercel.sh/v1")
            if not api_key:
                raise LLMUnavailableError("AI_GATEWAY_API_KEY is not set")
            self._backend = _OpenAIBackend(real_model, api_key, base_url=base_url)
        else:
            raise LLMUnavailableError(f"Unsupported provider kind: {provider_kind}")

    def complete(
        self,
        system: str,
        user: str,
        *,
        response_format: Literal["text", "json"] = "text",
        max_tokens: int = 1024,
        temperature: float = 0.7,
    ) -> LLMResponse:
        return self._backend.complete(
            system=system,
            user=user,
            response_format=response_format,
            max_tokens=max_tokens,
            temperature=temperature,
        )


def safe_llm(model: str = "gpt-5.5") -> LLM | None:
    """Return an :class:`LLM` if one can be constructed, else ``None``."""
    try:
        return LLM(model=model)
    except LLMUnavailableError:
        return None


__all__ = [
    "LLM",
    "LLMResponse",
    "LLMProvider",
    "LLMUnavailableError",
    "safe_llm",
    "json",  # re-exported for convenience
]
