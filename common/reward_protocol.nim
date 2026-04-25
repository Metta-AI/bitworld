import mummy
import std/[json, strutils, tables]

const
  RewardHttpPath* = "/reward"
  ResetInputMask* = 255'u8
  PendingPlayerIndex* = high(int)

type
  RewardMetric* = object
    score*, auxValue*: int

  RewardState* = object
    pendingClients: seq[string]
    clients: Table[WebSocket, string]
    metrics: Table[string, RewardMetric]
    episode: int

  RewardSnapshot* = object
    metric*: RewardMetric
    connected*: bool
    episode*: int

proc initRewardState*(): RewardState =
  result.pendingClients = @[]
  result.clients = initTable[WebSocket, string]()
  result.metrics = initTable[string, RewardMetric]()
  result.episode = 0

proc rewardClientKey*(remoteAddress: string): string =
  let colonCount = remoteAddress.count(':')
  if colonCount == 1:
    let portSep = remoteAddress.rfind(':')
    if portSep > 0:
      return remoteAddress[0 ..< portSep]
  remoteAddress

proc captureRewardClient*(state: var RewardState, remoteAddress: string) =
  state.pendingClients.add(rewardClientKey(remoteAddress))

proc takeRewardClient(state: var RewardState): string =
  if state.pendingClients.len == 0:
    return ""
  result = state.pendingClients[0]
  state.pendingClients.delete(0)

proc attachRewardClient*(state: var RewardState, websocket: WebSocket) =
  let rewardClient = state.takeRewardClient()
  state.clients[websocket] = rewardClient
  state.metrics[rewardClient] = RewardMetric()

proc detachRewardClient*(state: var RewardState, websocket: WebSocket) =
  if websocket notin state.clients:
    return
  let rewardClient = state.clients[websocket]
  state.clients.del(websocket)
  state.metrics.del(rewardClient)

proc resetRewardEpisode*(state: var RewardState) =
  inc state.episode
  for _, rewardClient in state.clients.pairs:
    state.metrics[rewardClient] = RewardMetric()

proc recordReward*(state: var RewardState, websocket: WebSocket, metric: RewardMetric) =
  if websocket in state.clients:
    state.metrics[state.clients[websocket]] = metric

proc lookupReward*(state: RewardState, remoteAddress: string): RewardSnapshot =
  let key = rewardClientKey(remoteAddress)
  if key in state.metrics:
    return RewardSnapshot(metric: state.metrics[key], connected: true, episode: state.episode)

  if state.metrics.len == 1:
    for _, metric in state.metrics.pairs:
      return RewardSnapshot(metric: metric, connected: true, episode: state.episode)

  RewardSnapshot(metric: RewardMetric(), connected: false, episode: state.episode)

proc respondReward*(
  request: Request,
  snapshot: RewardSnapshot
) =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Cache-Control"] = "no-store"
  request.respond(200, headers, $(%*{
    "reward": snapshot.metric.score,
    "score": snapshot.metric.score,
    "auxValue": snapshot.metric.auxValue,
    "episode": snapshot.episode,
    "connected": snapshot.connected
  }))
