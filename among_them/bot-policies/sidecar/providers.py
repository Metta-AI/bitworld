"""LLM provider implementations for the Among Them smart bot.

Supports:
  - bedrock:    AWS Bedrock (Claude via boto3.converse()) — primary
  - openrouter: OpenRouter API (any model) — fallback
  - anthropic:  Direct Anthropic API

Provider spec format: "provider" or "provider:model"
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

try:
  from dotenv import load_dotenv
  _env_path = Path(__file__).resolve().parent.parent / '.env.local'
  if _env_path.exists():
    load_dotenv(_env_path)
except ModuleNotFoundError:
  pass

logger = logging.getLogger('smartbot.providers')

_CODE_FENCE_RE = re.compile(r'^```(?:json)?\s*\n?(.*?)\n?```\s*$', re.DOTALL)


@dataclass
class LLMResponse:
  text: str
  parsed: dict | None
  latency_ms: float
  input_tokens: int
  output_tokens: int
  model: str


@dataclass
class ToolCall:
  tool_use_id: str
  name: str
  input: dict


@dataclass
class ToolResult:
  tool_use_id: str
  content: str
  is_error: bool = False


@dataclass
class ToolLoopResponse:
  text: str
  tool_calls_made: list
  latency_ms: float
  input_tokens: int
  output_tokens: int
  model: str
  rounds: int


def _strip_fences(text: str) -> str:
  m = _CODE_FENCE_RE.match(text.strip())
  return m.group(1).strip() if m else text.strip()


class BedrockProvider:
  """AWS Bedrock via boto3.converse()."""

  def __init__(self, model: str = 'us.anthropic.claude-sonnet-4-20250514'):
    self._model = model
    self._client = None
    self._region = os.getenv('AWS_REGION', 'us-east-1')
    self._profile = os.getenv('AWS_PROFILE', 'softmax')

  def _get_client(self):
    if self._client is None:
      import boto3
      if os.getenv('AWS_ACCESS_KEY_ID'):
        session = boto3.Session(region_name=self._region)
      else:
        session = boto3.Session(profile_name=self._profile, region_name=self._region)
      self._client = session.client('bedrock-runtime')
    return self._client

  def complete(self, system: str, messages: list[dict], max_tokens: int = 512) -> LLMResponse:
    client = self._get_client()
    t0 = time.monotonic()
    bedrock_msgs = [{'role': m['role'], 'content': [{'text': m['content']}]} for m in messages]
    response = client.converse(
      modelId=self._model,
      system=[{'text': system}],
      messages=bedrock_msgs,
      inferenceConfig={'temperature': 0, 'maxTokens': max_tokens},
    )
    latency = (time.monotonic() - t0) * 1000
    raw = ''
    for block in response.get('output', {}).get('message', {}).get('content', []):
      if 'text' in block:
        raw += block['text']
    usage = response.get('usage', {})
    return LLMResponse(
      text=_strip_fences(raw), parsed=None, latency_ms=round(latency),
      input_tokens=usage.get('inputTokens', 0),
      output_tokens=usage.get('outputTokens', 0), model=self._model,
    )

  def complete_with_tools(self, system: str, messages: list[dict], tools: list[dict],
                          tool_executor, max_tokens: int = 4096, max_rounds: int = 10) -> ToolLoopResponse:
    """Run a converse tool-use loop until the model stops calling tools."""
    client = self._get_client()
    t0 = time.monotonic()
    total_in = total_out = 0
    all_tool_calls = []
    bedrock_msgs = [{'role': m['role'], 'content': [{'text': m['content']}]} for m in messages]
    tool_config = {'tools': [{'toolSpec': t} for t in tools]}

    for round_num in range(1, max_rounds + 1):
      response = client.converse(
        modelId=self._model, system=[{'text': system}], messages=bedrock_msgs,
        toolConfig=tool_config, inferenceConfig={'temperature': 0, 'maxTokens': max_tokens},
      )
      usage = response.get('usage', {})
      total_in += usage.get('inputTokens', 0)
      total_out += usage.get('outputTokens', 0)
      stop_reason = response.get('stopReason', 'end_turn')
      output_content = response.get('output', {}).get('message', {}).get('content', [])
      bedrock_msgs.append({'role': 'assistant', 'content': output_content})

      if stop_reason != 'tool_use':
        final_text = ''.join(b.get('text', '') for b in output_content if 'text' in b)
        return ToolLoopResponse(text=final_text, tool_calls_made=all_tool_calls,
          latency_ms=round((time.monotonic() - t0) * 1000),
          input_tokens=total_in, output_tokens=total_out, model=self._model, rounds=round_num)

      tool_results_content = []
      for block in output_content:
        if 'toolUse' in block:
          tu = block['toolUse']
          tc = ToolCall(tool_use_id=tu['toolUseId'], name=tu['name'], input=tu['input'])
          all_tool_calls.append(tc)
          result = tool_executor(tc)
          tool_results_content.append({
            'toolResult': {'toolUseId': tc.tool_use_id, 'content': [{'text': result.content}],
                           'status': 'error' if result.is_error else 'success'}
          })
      bedrock_msgs.append({'role': 'user', 'content': tool_results_content})

    return ToolLoopResponse(text='(max rounds reached)', tool_calls_made=all_tool_calls,
      latency_ms=round((time.monotonic() - t0) * 1000),
      input_tokens=total_in, output_tokens=total_out, model=self._model, rounds=max_rounds)


class OpenRouterProvider:
  """OpenRouter API via httpx."""
  def __init__(self, model: str = 'anthropic/claude-haiku'):
    self._model = model
    self._api_key = os.environ.get('OPENROUTER_API_KEY', os.environ.get('OPENAI_API_KEY', ''))
    self._base_url = os.environ.get('OPENROUTER_BASE_URL', 'https://openrouter.ai/api/v1')

  def complete(self, system: str, messages: list[dict], max_tokens: int = 512) -> LLMResponse:
    import httpx
    all_messages = [{'role': 'system', 'content': system}] + messages
    t0 = time.monotonic()
    resp = httpx.post(f'{self._base_url}/chat/completions',
      headers={'Authorization': f'Bearer {self._api_key}', 'Content-Type': 'application/json'},
      json={'model': self._model, 'messages': all_messages, 'temperature': 0, 'max_tokens': max_tokens},
      timeout=30.0)
    latency = (time.monotonic() - t0) * 1000
    resp.raise_for_status()
    data = resp.json()
    raw = data['choices'][0]['message']['content']
    usage = data.get('usage', {})
    return LLMResponse(text=_strip_fences(raw), parsed=None, latency_ms=round(latency),
      input_tokens=usage.get('prompt_tokens', 0), output_tokens=usage.get('completion_tokens', 0),
      model=self._model)


class AnthropicProvider:
  """Direct Anthropic API via httpx."""
  def __init__(self, model: str = 'claude-haiku-4-20250414'):
    self._model = model
    self._api_key = os.environ.get('ANTHROPIC_API_KEY', '')

  def complete(self, system: str, messages: list[dict], max_tokens: int = 512) -> LLMResponse:
    import httpx
    t0 = time.monotonic()
    resp = httpx.post('https://api.anthropic.com/v1/messages',
      headers={'x-api-key': self._api_key, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json'},
      json={'model': self._model, 'system': system, 'messages': messages, 'temperature': 0, 'max_tokens': max_tokens},
      timeout=30.0)
    latency = (time.monotonic() - t0) * 1000
    resp.raise_for_status()
    data = resp.json()
    raw = data['content'][0]['text']
    usage = data.get('usage', {})
    return LLMResponse(text=_strip_fences(raw), parsed=None, latency_ms=round(latency),
      input_tokens=usage.get('input_tokens', 0), output_tokens=usage.get('output_tokens', 0),
      model=self._model)


_DEFAULTS = {
  'bedrock': 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
  'openrouter': 'anthropic/claude-haiku',
  'anthropic': 'claude-haiku-4-20250414',
}
_ANALYSIS_DEFAULTS = {
  'bedrock': 'us.anthropic.claude-opus-4-6-v1',
  'openrouter': 'anthropic/claude-opus-4',
  'anthropic': 'claude-opus-4-6-20250620',
}
_EVOLUTION_DEFAULTS = {
  'bedrock': 'us.anthropic.claude-opus-4-6-v1',
  'openrouter': 'anthropic/claude-opus-4',
  'anthropic': 'claude-opus-4-6-20250620',
}
_CLASSES = {
  'bedrock': BedrockProvider,
  'openrouter': OpenRouterProvider,
  'anthropic': AnthropicProvider,
}


def create_provider(spec: str):
  if ':' in spec:
    provider_name, model = spec.split(':', 1)
  else:
    provider_name, model = spec, None
  provider_name = provider_name.lower()
  if provider_name not in _CLASSES:
    raise ValueError(f'Unknown provider: {provider_name}. Use: {", ".join(_CLASSES)}')
  return _CLASSES[provider_name](model=model or _DEFAULTS[provider_name])


def create_analysis_provider(spec: str):
  provider_name = spec.split(':')[0].lower()
  if provider_name not in _CLASSES:
    raise ValueError(f'Unknown provider: {provider_name}')
  return _CLASSES[provider_name](model=_ANALYSIS_DEFAULTS[provider_name])


def create_evolution_provider(spec: str):
  if ':' in spec:
    provider_name, model = spec.split(':', 1)
  else:
    provider_name, model = spec, None
  provider_name = provider_name.lower()
  if provider_name not in _CLASSES:
    raise ValueError(f'Unknown provider: {provider_name}')
  return _CLASSES[provider_name](model=model or _EVOLUTION_DEFAULTS[provider_name])
