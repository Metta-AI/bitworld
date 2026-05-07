"""``@tool`` decorator and a thin ``ToolLoop``.

Cyborg's ``framework.providers.complete_with_tools`` is Bedrock-shaped and
not directly usable across providers, so we ship a minimal Pydantic-driven
tool spec here. The decorator inspects the function signature, builds an
input model, and stores both the model and the executor.

A ``ToolLoop`` runs an LLM in a "respond OR call a tool" loop until the
``stop_when`` predicate returns true on a tool result. This mirrors Vercel
AI SDK's ``ToolLoopAgent`` semantics — small but useful when you want to wire
an LLM voter or chatter without depending on a full agent framework.
"""

from __future__ import annotations

import inspect
import json
import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from pydantic import BaseModel, create_model

logger = logging.getLogger("among_them_sdk.cognition.tools")


@dataclass
class Tool:
    name: str
    description: str
    input_model: type[BaseModel]
    func: Callable[..., Any]

    def call(self, **kwargs: Any) -> Any:
        validated = self.input_model(**kwargs)
        return self.func(**validated.model_dump())

    def schema(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "input_schema": self.input_model.model_json_schema(),
        }


def tool(_func: Callable[..., Any] | None = None, *, name: str | None = None,
         description: str | None = None) -> Any:
    """Decorate a Python function to register it as a callable LLM tool."""

    def wrap(func: Callable[..., Any]) -> Tool:
        sig = inspect.signature(func)
        fields: dict[str, Any] = {}
        for param_name, param in sig.parameters.items():
            if param_name == "self":
                continue
            annotation = param.annotation if param.annotation is not inspect._empty else Any
            default = param.default if param.default is not inspect._empty else ...
            fields[param_name] = (annotation, default)
        model_name = f"{func.__name__.title().replace('_', '')}Input"
        input_model = create_model(model_name, **fields)  # type: ignore[call-overload]
        return Tool(
            name=name or func.__name__,
            description=description or (func.__doc__ or "").strip().split("\n", 1)[0],
            input_model=input_model,
            func=func,
        )

    if _func is None:
        return wrap
    return wrap(_func)


class ToolLoop:
    """Run an LLM in a respond/tool-call loop until ``stop_when`` returns true.

    This is a *simple* implementation suitable for low-stakes mix-ins (e.g.
    LLMVoter). It does not stream, does not parallelize tools, and lets the
    model emit either a JSON tool call or a final answer. For richer tool
    semantics use the Anthropic / OpenAI tools APIs directly.
    """

    def __init__(
        self,
        llm: Any,  # LLM
        tools: list[Tool],
        *,
        stop_when: Callable[[Any], bool] | None = None,
        max_rounds: int = 4,
    ):
        self.llm = llm
        self.tools = {t.name: t for t in tools}
        self.stop_when = stop_when
        self.max_rounds = max_rounds

    def _system_prompt(self, base: str) -> str:
        tool_blob = json.dumps([t.schema() for t in self.tools.values()], indent=2)
        return (
            f"{base}\n\n"
            f"You have access to these tools:\n{tool_blob}\n\n"
            "To call a tool, respond ONLY with JSON of the form:\n"
            '{ "tool": "<name>", "args": { ... } }\n'
            "When you are done, respond with JSON of the form:\n"
            '{ "answer": <your-final-answer> }'
        )

    def run(self, *, system: str, user: str) -> Any:
        prompt_user = user
        last_result: Any = None
        for round_idx in range(self.max_rounds):
            resp = self.llm.complete(
                system=self._system_prompt(system),
                user=prompt_user,
                response_format="json",
            )
            try:
                payload = json.loads(resp.text)
            except json.JSONDecodeError:
                logger.warning("ToolLoop: non-JSON response on round %d: %s", round_idx, resp.text[:200])
                return resp.text
            if "answer" in payload:
                return payload["answer"]
            tool_name = payload.get("tool")
            args = payload.get("args", {})
            if not tool_name or tool_name not in self.tools:
                logger.warning("ToolLoop: unknown tool %r", tool_name)
                return None
            try:
                last_result = self.tools[tool_name].call(**args)
            except Exception as exc:
                logger.warning("ToolLoop: tool %s raised %s", tool_name, exc)
                prompt_user = f"{user}\n\nTool {tool_name} raised: {exc}. Try again."
                continue
            if self.stop_when and self.stop_when(last_result):
                return last_result
            prompt_user = f"{user}\n\nTool {tool_name} returned: {last_result!r}. Continue."
        return last_result


__all__ = ["Tool", "ToolLoop", "tool"]
