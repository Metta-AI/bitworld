## Single-worker-thread LLM dispatcher (Sprint 6.2).
##
## Wraps `llm_provider.complete` with a worker thread + two
## `Channel`s so the bot's per-frame loop stays non-blocking.
##
## Why single-worker: the CLI binary is one-agent-per-process. The
## Python wrapper's `ThreadPoolExecutor` (Sprint 4.1) handled
## `num_agents` concurrent calls because it ran N agents in one
## process; for the CLI path we don't have that constraint.
## `quick_player`-spawned bots get concurrency for free by being
## separate processes.
##
## At any moment ≤ 1 LLM call is in flight per process. The Nim
## state machine respects single-slot semantics
## (`LlmRequestSlot.pending`) so a second submit before the first
## completes is a programmer error and is logged + dropped.
##
## Lifecycle:
##   1. `initLlmDispatcher(provider)` spawns the worker.
##   2. Per frame: caller checks `bot.llmVoting.request.pending`.
##      If true and `submit` returns true (slot was empty),
##      a worker call kicks off.
##   3. Per frame: caller calls `tryGather` once. If it returns
##      `some(...)`, the result is fed via `onLlmResponse`.
##   4. On shutdown: `closeLlmDispatcher` stops the worker and
##      closes channels. Idempotent.

import std/[atomics, options]

import types
import llm_provider

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  LlmDispatchRequest* = object
    role*: BotRole
    kind*: LlmCallKind
    contextJson*: string

  LlmDispatchResult* = object
    kind*: LlmCallKind
    responseJson*: string
    errored*: bool
    latencyMs*: int

  WorkerCtx = object
    ## Heap-allocated context shared with the worker thread.
    ## Allocated once at `initLlmDispatcher` and freed at
    ## `closeLlmDispatcher`. Not exported.
    requests:  Channel[LlmDispatchRequest]
    results:   Channel[LlmDispatchResult]
    shutdown:  Atomic[bool]
    provider:  LlmProvider

  LlmDispatcher* = ref object
    ## Owner-side handle. The worker thread holds a `ptr WorkerCtx`
    ## directly so it doesn't have to share a Nim ref with the
    ## main thread (refs across threads under ORC require care
    ## that's not worth the complexity here).
    thread:    Thread[ptr WorkerCtx]
    ctx:       ptr WorkerCtx
    inflight:  bool
    closed:    bool

# ---------------------------------------------------------------------------
# Worker thread body
# ---------------------------------------------------------------------------

proc workerLoop(ctx: ptr WorkerCtx) {.thread.} =
  ## Pulls one request at a time, calls `complete`, posts the
  ## result back. Exits when the request channel is closed (which
  ## `closeLlmDispatcher` does after flipping `shutdown`).
  while true:
    let (received, req) = ctx.requests.tryRecv()
    if not received:
      # Block briefly on a real recv. If the channel has been
      # closed (shutdown path), `recv` raises and we exit.
      try:
        let blockingReq = ctx.requests.recv()
        if ctx.shutdown.load():
          break
        let res = ctx.provider.complete(
          blockingReq.role, blockingReq.kind, blockingReq.contextJson
        )
        let dispatched = LlmDispatchResult(
          kind: blockingReq.kind,
          responseJson: res.responseJson,
          errored: res.errored,
          latencyMs: res.latencyMs
        )
        ctx.results.send(dispatched)
      except CatchableError:
        break
      continue
    if ctx.shutdown.load():
      break
    let res = ctx.provider.complete(req.role, req.kind, req.contextJson)
    let dispatched = LlmDispatchResult(
      kind: req.kind,
      responseJson: res.responseJson,
      errored: res.errored,
      latencyMs: res.latencyMs
    )
    try:
      ctx.results.send(dispatched)
    except CatchableError:
      break

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc initLlmDispatcher*(provider: LlmProvider): LlmDispatcher =
  ## Allocates the worker context + spawns the thread. The caller
  ## owns the returned `LlmDispatcher` and must call
  ## `closeLlmDispatcher` before shutdown.
  ##
  ## Returns a non-nil dispatcher even when the provider is
  ## disabled — the worker simply receives nothing in that case
  ## (the per-frame poll loop checks `provider.enabled` and
  ## skips submit). Keeping the dispatcher alive in the disabled
  ## case avoids special-casing in the runner.
  result = LlmDispatcher()
  result.ctx = create(WorkerCtx)
  result.ctx.provider = provider
  result.ctx.shutdown.store(false)
  result.ctx.requests.open()
  result.ctx.results.open()
  createThread(result.thread, workerLoop, result.ctx)

proc submit*(d: LlmDispatcher; req: LlmDispatchRequest): bool =
  ## Queues a request for the worker. Returns true on accept,
  ## false if a request is already in flight (slot already taken
  ## but not yet drained by `tryGather`).
  ##
  ## **Single-slot rule:** the bot's state machine guarantees only
  ## one `llmTakePendingRequest` returns a non-`lckNone` kind at a
  ## time. So in practice `submit` should never refuse. This
  ## belt-and-suspenders check is here in case a future state-
  ## machine bug violates the invariant — at least we don't pile
  ## up calls.
  if d.isNil or d.closed:
    return false
  if d.inflight:
    return false
  if not d.ctx.provider.enabled():
    # Disabled provider: skip the wire entirely; immediately put
    # an errored result on the queue so `tryGather` sees it next
    # tick (caller's `onLlmResponse(errored=true)` then fires the
    # rule-based fallback).
    let errored = LlmDispatchResult(
      kind: req.kind, responseJson: "", errored: true, latencyMs: 0
    )
    try:
      d.ctx.results.send(errored)
    except CatchableError:
      return false
    d.inflight = true
    return true
  try:
    d.ctx.requests.send(req)
  except CatchableError:
    return false
  d.inflight = true
  true

proc tryGather*(d: LlmDispatcher): Option[LlmDispatchResult] =
  ## Non-blocking poll. Returns `some(result)` if the worker has
  ## produced one since the last call, else `none`. Clears the
  ## in-flight flag on success so the next `submit` succeeds.
  if d.isNil or d.closed:
    return none(LlmDispatchResult)
  let (received, res) = d.ctx.results.tryRecv()
  if not received:
    return none(LlmDispatchResult)
  d.inflight = false
  some(res)

proc inflightCount*(d: LlmDispatcher): int =
  ## 0 or 1 — for diagnostic / trace use.
  if d.isNil or d.closed: 0
  elif d.inflight: 1
  else: 0

proc closeLlmDispatcher*(d: LlmDispatcher) =
  ## Stops the worker and frees the context. Idempotent. Safe to
  ## call from a `defer` block in `runBot`.
  if d.isNil or d.closed:
    return
  d.closed = true
  d.ctx.shutdown.store(true)
  # Send a sentinel request to unblock the worker's `recv`. The
  # worker checks `shutdown` after recv returns and exits cleanly.
  try:
    d.ctx.requests.send(LlmDispatchRequest(kind: lckNone))
  except CatchableError:
    discard
  joinThread(d.thread)
  d.ctx.requests.close()
  d.ctx.results.close()
  dealloc(d.ctx)
  d.ctx = nil
