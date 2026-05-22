import
  std/[
    json, net, os, osproc, parseopt, streams, strutils, sysrand, tables,
    times, uri
  ],
  whisky

from std/httpclient import close, get, newHttpClient

const
  DefaultTimeoutSeconds = 60.0
  ContainerWorkDir = "/coworld"
  DockerBinEnv = "COGAME_VALIDATOR_DOCKER"
  GamePort = 8080
  HealthPath = "/healthz"
  PlayerPath = "/player"
  GlobalPath = "/global"
  AdminPath = "/admin"
  ReplayClientPath = "/client/replay"
  ReplaySocketPath = "/replay"
  ConfigEnv = "COGAME_CONFIG_URI"
  ResultsEnv = "COGAME_RESULTS_URI"
  ReplaySaveEnv = "COGAME_SAVE_REPLAY_URI"
  ReplayLoadEnv = "COGAME_LOAD_REPLAY_URI"
  ReplayServerEnv = "COGAME_REPLAY_SERVER"
  HostEnv = "COGAME_HOST"
  PortEnv = "COGAME_PORT"
  EngineWsEnv = "COGAMES_ENGINE_WS_URL"
  AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]
  CertPrefix = "coworld-cert-"

type
  CogameValidatorError* = object of CatchableError

  CriterionStatus* = enum
    CriterionPass,
    CriterionFail,
    CriterionSkip

  ValidationCriterion* = object
    id*: string
    name*: string
    status*: CriterionStatus
    message*: string

  QueryParam* = object
    key*: string
    value*: string

  PlayerLaunchSpec* = object
    image*: string
    command*: seq[string]
    env*: seq[(string, string)]
    initialParams*: seq[QueryParam]

  CogameProtocolDocs* = object
    player*: string
    global*: string
    reward*: string

  CoworldPackage* = object
    manifestPath*: string
    manifest*: JsonNode
    certification*: JsonNode
    cogameImage*: string
    cogameCommand*: seq[string]
    cogameEnv*: seq[(string, string)]
    configSchema*: JsonNode
    resultsSchema*: JsonNode
    protocols*: CogameProtocolDocs

  EpisodeArtifacts* = object
    workspace*: string
    configPath*: string
    resultsPath*: string
    replayPath*: string
    logsDir*: string
    gameLogPath*: string

  EpisodeRunSpec* = object
    cogameImage*: string
    cogameCommand*: seq[string]
    cogameEnv*: seq[(string, string)]
    containerPort*: int
    players*: seq[PlayerLaunchSpec]
    tokens*: seq[string]
    artifacts*: EpisodeArtifacts
    timeoutSeconds*: float
    dockerBin*: string

  CertificationResult* = object
    coworld*: CoworldPackage
    artifacts*: EpisodeArtifacts
    episodeRequest*: JsonNode
    results*: JsonNode
    criteria*: seq[ValidationCriterion]

  ValidatorConfig* = object
    workspace*: string
    timeoutSeconds*: float
    dockerBin*: string
    checkImages*: bool
    runContainers*: bool

  DockerResult = object
    output: string
    code: int

proc fail(message: string) =
  ## Raises a validator-specific exception with one message.
  raise newException(CogameValidatorError, message)

proc cleanPath(path: string): string =
  ## Returns an absolute normalized path.
  absolutePath(path).normalizedPath()

proc repoRoot(): string =
  ## Returns the Bitworld repository root.
  parentDir(parentDir(currentSourcePath()))

proc defaultDockerBin(): string =
  ## Returns the Docker-compatible command to run.
  result = getEnv(DockerBinEnv, "docker").strip()
  if result.len == 0:
    result = "docker"

proc defaultValidatorConfig*(): ValidatorConfig =
  ## Returns the default validator settings.
  ValidatorConfig(
    workspace: "",
    timeoutSeconds: DefaultTimeoutSeconds,
    dockerBin: defaultDockerBin(),
    checkImages: true,
    runContainers: true
  )

proc addCriterion(
  criteria: var seq[ValidationCriterion],
  id,
  name: string,
  status: CriterionStatus,
  message = ""
) =
  ## Appends one validation criterion result.
  criteria.add(ValidationCriterion(
    id: id,
    name: name,
    status: status,
    message: message
  ))

proc passCriterion(
  criteria: var seq[ValidationCriterion],
  id,
  name: string,
  message = ""
) =
  ## Appends a passing validation criterion.
  criteria.addCriterion(id, name, CriterionPass, message)

proc failCriterion(
  criteria: var seq[ValidationCriterion],
  id,
  name,
  message: string
) =
  ## Appends a failing validation criterion.
  criteria.addCriterion(id, name, CriterionFail, message)

proc skipCriterion(
  criteria: var seq[ValidationCriterion],
  id,
  name,
  message: string
) =
  ## Appends a skipped validation criterion.
  criteria.addCriterion(id, name, CriterionSkip, message)

proc criteriaPassed*(criteria: openArray[ValidationCriterion]): bool =
  ## Returns true when no criterion failed.
  for criterion in criteria:
    if criterion.status == CriterionFail:
      return false
  true

proc validationPassed*(certification: CertificationResult): bool =
  ## Returns true when the certification result has no failed criteria.
  criteriaPassed(certification.criteria)

proc requireKind(node: JsonNode, kind: JsonNodeKind, path: string) =
  ## Raises when a JSON node is not the expected kind.
  if node.kind != kind:
    fail(path & " must be " & $kind)

proc requireKey(node: JsonNode, key, path: string): JsonNode =
  ## Returns one required object field.
  node.requireKind(JObject, path)
  if not node.hasKey(key):
    fail(path & " missing required field " & key)
  node[key]

proc optionalKey(node: JsonNode, key: string): JsonNode =
  ## Returns one optional object field or nil.
  if node.kind == JObject and node.hasKey(key):
    return node[key]
  nil

proc requireString(node: JsonNode, key, path: string): string =
  ## Returns one required non-empty string field.
  let child = node.requireKey(key, path)
  if child.kind != JString or child.getStr().len == 0:
    fail(path & "." & key & " must be a non-empty string")
  child.getStr()

proc requireObject(node: JsonNode, key, path: string): JsonNode =
  ## Returns one required object field.
  let child = node.requireKey(key, path)
  child.requireKind(JObject, path & "." & key)
  child

proc requireArray(node: JsonNode, key, path: string): JsonNode =
  ## Returns one required array field.
  let child = node.requireKey(key, path)
  child.requireKind(JArray, path & "." & key)
  child

proc docValue(node: JsonNode, path: string): string =
  ## Returns a protocol doc string from either legacy strings or doc objects.
  if node.kind == JString and node.getStr().len > 0:
    return node.getStr()
  node.requireKind(JObject, path)
  discard node.requireString("type", path)
  let value = node.requireString("value", path)
  if value.len == 0:
    fail(path & ".value must be a non-empty string")
  value

proc requireDoc(node: JsonNode, key, path: string): string =
  ## Returns one required protocol document value.
  node.requireKey(key, path).docValue(path & "." & key)

proc optionalDoc(node: JsonNode, key, path: string): string =
  ## Returns one optional protocol document value.
  let child = node.optionalKey(key)
  if child.isNil:
    return ""
  child.docValue(path & "." & key)

proc protocolDocs(protocols: JsonNode): CogameProtocolDocs =
  ## Parses Coworld protocol docs.
  CogameProtocolDocs(
    player: protocols.requireDoc("player", "coworld.game.protocols"),
    global: protocols.requireDoc("global", "coworld.game.protocols"),
    reward: protocols.optionalDoc("reward", "coworld.game.protocols")
  )

proc requireImage(node: JsonNode, path: string): string =
  ## Returns one required Docker image field.
  node.requireKind(JObject, path)
  let runnable = node.optionalKey("runnable")
  if not runnable.isNil:
    runnable.requireKind(JObject, path & ".runnable")
    let image = runnable.optionalKey("image")
    if not image.isNil and image.kind == JString and image.getStr().len > 0:
      return image.getStr()
  for key in ["image", "image_uri"]:
    let image = node.optionalKey(key)
    if not image.isNil and image.kind == JString and image.getStr().len > 0:
      return image.getStr()
  fail(path & " missing image")

proc requireRunCommand(node: JsonNode, path: string): seq[string] =
  ## Returns one required Coworld runnable command array.
  node.requireKind(JObject, path)
  let runnable = node.optionalKey("runnable")
  if not runnable.isNil:
    runnable.requireKind(JObject, path & ".runnable")
    let run = runnable.optionalKey("run")
    if not run.isNil:
      run.requireKind(JArray, path & ".runnable.run")
      for i in 0 ..< run.len:
        if run[i].kind != JString or run[i].getStr().len == 0:
          fail(path & ".runnable.run[" & $i & "] must be a non-empty string")
        result.add(run[i].getStr())
  if result.len == 0:
    let run = node.optionalKey("run")
    if not run.isNil:
      run.requireKind(JArray, path & ".run")
      for i in 0 ..< run.len:
        if run[i].kind != JString or run[i].getStr().len == 0:
          fail(path & ".run[" & $i & "] must be a non-empty string")
        result.add(run[i].getStr())
  if result.len == 0:
    fail(path & " missing run")

proc manifestEnv(node: JsonNode): seq[(string, string)] =
  ## Reads one manifest env object.
  node.requireKind(JObject, "manifest node")
  let env = node.optionalKey("env")
  if env.isNil:
    return
  env.requireKind(JObject, "manifest env")
  for key, value in env.pairs:
    if value.kind != JString:
      fail("manifest env " & key & " must be a string")
    result.add((key, value.getStr()))

proc hexBytes(bytes: openArray[byte]): string =
  ## Encodes bytes as lowercase hexadecimal.
  const HexChars = "0123456789abcdef"
  for b in bytes:
    result.add(HexChars[int(b shr 4)])
    result.add(HexChars[int(b and 0x0f)])

proc fileUri*(path: string): string =
  ## Returns a file URI for one local path.
  "file://" & cleanPath(path).replace("\\", "/")

proc loadJsonObject*(path: string): JsonNode =
  ## Loads a JSON object from disk.
  try:
    result = parseJson(readFile(path))
  except CatchableError as e:
    fail("could not read JSON object " & path & ": " & e.msg)
  if result.kind != JObject:
    fail("expected JSON object in " & path)

proc resolveManifestUri*(baseDir, manifestUri: string): string =
  ## Resolves a local manifest URI relative to a base directory.
  let parsed = parseUri(manifestUri)
  if parsed.scheme == "file":
    return cleanPath(decodeUrl(parsed.path))
  if parsed.scheme.len > 0:
    fail("only local manifest URIs are supported: " & manifestUri)
  cleanPath(baseDir / manifestUri)

proc isLocalManifestUri(manifestUri: string): bool =
  ## Returns true when a manifest URI points to a local file.
  let parsed = parseUri(manifestUri)
  parsed.scheme.len == 0 or parsed.scheme == "file"

proc isCoworldManifest(node: JsonNode): bool =
  ## Returns true when a JSON object looks like a Coworld manifest.
  node.kind == JObject and node.hasKey("game") and node.hasKey("certification")

proc valueToQueryString(node: JsonNode): string =
  ## Converts a simple JSON scalar to a query parameter value.
  case node.kind
  of JString:
    result = node.getStr()
  of JInt:
    result = $node.getBiggestInt()
  of JFloat:
    result = $node.getFloat()
  of JBool:
    result =
      if node.getBool():
        "True"
      else:
        "False"
  else:
    fail("initial_params values must be strings, numbers, or booleans")

proc encodeUrlComponent(value: string): string =
  ## Encodes a string for use in one URL query component.
  for c in value:
    case c
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~':
      result.add(c)
    else:
      result.add('%')
      result.add(ord(c).toHex(2))

proc queryString(params: openArray[QueryParam]): string =
  ## Builds a URL query string from explicit key/value pairs.
  for i, param in params:
    if i > 0:
      result.add('&')
    result.add(encodeUrlComponent(param.key))
    result.add('=')
    result.add(encodeUrlComponent(param.value))

proc jsonNumber(node: JsonNode): float =
  ## Returns a JSON integer or float as a float.
  case node.kind
  of JInt:
    result = node.getBiggestInt().float
  of JFloat:
    result = node.getFloat()
  else:
    fail("schema numeric bound must be a number")

proc schemaTypes(schema: JsonNode): seq[string] =
  ## Returns the JSON Schema type list for one schema node.
  let typeNode = schema.optionalKey("type")
  if typeNode.isNil:
    return
  case typeNode.kind
  of JString:
    result.add(typeNode.getStr())
  of JArray:
    for item in typeNode:
      if item.kind != JString:
        fail("schema type array values must be strings")
      result.add(item.getStr())
  else:
    fail("schema type must be a string or string array")

proc jsonTypeMatches(node: JsonNode, schemaType: string): bool =
  ## Returns true when one JSON node matches one schema type name.
  case schemaType
  of "object":
    node.kind == JObject
  of "array":
    node.kind == JArray
  of "string":
    node.kind == JString
  of "integer":
    node.kind == JInt
  of "number":
    node.kind in {JInt, JFloat}
  of "boolean":
    node.kind == JBool
  of "null":
    node.kind == JNull
  else:
    true

proc validateJsonSchema*(instance, schema: JsonNode, path = "$")

proc validateObjectSchema(instance, schema: JsonNode, path: string) =
  ## Validates object-specific JSON Schema rules.
  if instance.kind != JObject:
    return
  let required = schema.optionalKey("required")
  if not required.isNil:
    required.requireKind(JArray, path & ".required")
    for item in required:
      if item.kind != JString:
        fail(path & ".required values must be strings")
      if not instance.hasKey(item.getStr()):
        fail(path & " missing required field " & item.getStr())

  let properties = schema.optionalKey("properties")
  if not properties.isNil:
    properties.requireKind(JObject, path & ".properties")
    for key, propertySchema in properties.pairs:
      if instance.hasKey(key):
        validateJsonSchema(instance[key], propertySchema, path & "." & key)

  let additional = schema.optionalKey("additionalProperties")
  if not additional.isNil and not properties.isNil:
    for key, value in instance.pairs:
      if not properties.hasKey(key):
        case additional.kind
        of JBool:
          if not additional.getBool():
            fail(path & " has unknown field " & key)
        of JObject:
          validateJsonSchema(value, additional, path & "." & key)
        else:
          discard

proc validateArraySchema(instance, schema: JsonNode, path: string) =
  ## Validates array-specific JSON Schema rules.
  if instance.kind != JArray:
    return
  let minItems = schema.optionalKey("minItems")
  if not minItems.isNil and instance.len < minItems.getInt():
    fail(path & " must contain at least " & $minItems.getInt() & " item(s)")
  let maxItems = schema.optionalKey("maxItems")
  if not maxItems.isNil and instance.len > maxItems.getInt():
    fail(path & " must contain at most " & $maxItems.getInt() & " item(s)")
  let items = schema.optionalKey("items")
  if not items.isNil and items.kind == JObject:
    for i in 0 ..< instance.len:
      let item = instance[i]
      validateJsonSchema(item, items, path & "[" & $i & "]")

proc validateStringSchema(instance, schema: JsonNode, path: string) =
  ## Validates string-specific JSON Schema rules.
  if instance.kind != JString:
    return
  let minLength = schema.optionalKey("minLength")
  if not minLength.isNil and instance.getStr().len < minLength.getInt():
    fail(path & " must not be empty")

proc validateNumberSchema(instance, schema: JsonNode, path: string) =
  ## Validates number-specific JSON Schema rules.
  if instance.kind notin {JInt, JFloat}:
    return
  let value = instance.jsonNumber()
  let minimum = schema.optionalKey("minimum")
  if not minimum.isNil and value < minimum.jsonNumber():
    fail(path & " must be at least " & $minimum.jsonNumber())
  let maximum = schema.optionalKey("maximum")
  if not maximum.isNil and value > maximum.jsonNumber():
    fail(path & " must be at most " & $maximum.jsonNumber())

proc validateEnumSchema(instance, schema: JsonNode, path: string) =
  ## Validates enum membership when present.
  let enumNode = schema.optionalKey("enum")
  if enumNode.isNil:
    return
  enumNode.requireKind(JArray, path & ".enum")
  for item in enumNode:
    if item == instance:
      return
  fail(path & " has a value outside the allowed enum")

proc validateAllOfSchema(instance, schema: JsonNode, path: string) =
  ## Validates allOf schema branches when present.
  let allOf = schema.optionalKey("allOf")
  if allOf.isNil:
    return
  allOf.requireKind(JArray, path & ".allOf")
  for branch in allOf:
    if branch.kind == JObject:
      validateJsonSchema(instance, branch, path)

proc validateJsonSchema*(instance, schema: JsonNode, path = "$") =
  ## Validates a practical subset of JSON Schema used by Coworld manifests.
  if schema.isNil or schema.kind != JObject:
    return
  validateAllOfSchema(instance, schema, path)
  let types = schema.schemaTypes()
  if types.len > 0:
    var matched = false
    for schemaType in types:
      if instance.jsonTypeMatches(schemaType):
        matched = true
        break
    if not matched:
      fail(path & " has the wrong JSON type")
  validateObjectSchema(instance, schema, path)
  validateArraySchema(instance, schema, path)
  validateStringSchema(instance, schema, path)
  validateNumberSchema(instance, schema, path)
  validateEnumSchema(instance, schema, path)

proc validateNamedImages(section: JsonNode, path: string, requireRun = false) =
  ## Validates a Coworld named-image array.
  section.requireKind(JArray, path)
  if section.len == 0:
    fail(path & " must not be empty")
  for i in 0 ..< section.len:
    let item = section[i]
    let itemPath = path & "[" & $i & "]"
    item.requireKind(JObject, itemPath)
    discard item.requireString("id", itemPath)
    discard item.requireString("name", itemPath)
    discard item.requireImage(itemPath)
    if requireRun:
      discard item.requireRunCommand(itemPath)
    discard item.requireString("description", itemPath)

proc validateVariants(section: JsonNode, path: string) =
  ## Validates a Coworld variant array.
  section.requireKind(JArray, path)
  if section.len == 0:
    fail(path & " must not be empty")
  for i in 0 ..< section.len:
    let item = section[i]
    let itemPath = path & "[" & $i & "]"
    item.requireKind(JObject, itemPath)
    discard item.requireString("id", itemPath)
    discard item.requireString("name", itemPath)
    discard item.requireString("description", itemPath)
    discard item.requireObject("game_config", itemPath)

proc validateCoworldGame(game: JsonNode) =
  ## Validates embedded Coworld game fields needed by certification.
  game.requireKind(JObject, "coworld.game")
  discard game.requireString("name", "coworld.game")
  discard game.requireString("version", "coworld.game")
  discard game.requireString("description", "coworld.game")
  discard game.requireString("owner", "coworld.game")
  discard game.requireImage("coworld.game")
  discard game.requireRunCommand("coworld.game")
  discard game.requireObject("config_schema", "coworld.game")
  discard game.requireObject("results_schema", "coworld.game")
  let protocols = game.requireObject("protocols", "coworld.game")
  discard protocols.protocolDocs()

proc validateCoworldManifest*(manifest: JsonNode) =
  ## Validates the Coworld fields needed by certification.
  manifest.requireKind(JObject, "coworld")
  validateCoworldGame(manifest.requireObject("game", "coworld"))
  validateNamedImages(
    manifest.requireArray("player", "coworld"),
    "coworld.player",
    requireRun = true
  )
  validateVariants(manifest.requireArray("variants", "coworld"), "coworld.variants")

  for section in ["grader", "reporter", "commissioner", "diagnoser", "optimizer"]:
    let node = manifest.optionalKey(section)
    if not node.isNil:
      validateNamedImages(node, "coworld." & section)

  let certification = manifest.requireObject("certification", "coworld")
  let hasVariant = certification.optionalKey("variant_id") != nil
  let hasConfig = certification.optionalKey("game_config") != nil
  if not hasVariant and not hasConfig:
    fail("coworld.certification missing variant_id or game_config")
  if hasVariant:
    discard certification.requireString("variant_id", "coworld.certification")
  if hasConfig:
    discard certification.requireObject("game_config", "coworld.certification")
  let players = certification.requireArray("players", "coworld.certification")
  if players.len == 0:
    fail("coworld.certification.players must not be empty")
  for i in 0 ..< players.len:
    let item = players[i]
    let itemPath = "coworld.certification.players[" & $i & "]"
    item.requireKind(JObject, itemPath)
    discard item.requireString("player_id", itemPath)
    let params = item.optionalKey("initial_params")
    if not params.isNil:
      params.requireKind(JObject, itemPath & ".initial_params")
      for key, value in params.pairs:
        discard key
        discard value.valueToQueryString()

proc itemMapById(manifest: JsonNode, section: string): Table[string, JsonNode] =
  ## Indexes a Coworld array section by id.
  let items = manifest.requireArray(section, "coworld")
  for item in items:
    let itemId = item.requireString("id", "coworld." & section)
    if result.hasKey(itemId):
      fail("duplicate " & section & " id: " & itemId)
    result[itemId] = item

proc certificationVariant*(coworld: CoworldPackage): JsonNode =
  ## Returns the Coworld variant used for certification.
  if not coworld.certification.optionalKey("game_config").isNil:
    return coworld.certification
  let variants = itemMapById(coworld.manifest, "variants")
  let variantId =
    coworld.certification.requireString("variant_id", "coworld.certification")
  if not variants.hasKey(variantId):
    fail("unknown certification variant_id: " & variantId)
  variants[variantId]

proc certificationPlayerLaunchSpecs*(
  coworld: CoworldPackage
): seq[PlayerLaunchSpec] =
  ## Returns player containers referenced by certification slots.
  let
    declaredPlayers = itemMapById(coworld.manifest, "player")
    players = coworld.certification.requireArray(
      "players",
      "coworld.certification"
    )
  for slot in 0 ..< players.len:
    let rawPlayer = players[slot]
    let
      playerId = rawPlayer.requireString(
        "player_id",
        "coworld.certification.players[" & $slot & "]"
      )
    if not declaredPlayers.hasKey(playerId):
      fail("unknown certification player_id for slot " & $slot & ": " & playerId)
    let declaredPlayer = declaredPlayers[playerId]
    var spec = PlayerLaunchSpec(
      image: declaredPlayer.requireImage("coworld.player"),
      command: declaredPlayer.requireRunCommand("coworld.player"),
      env: declaredPlayer.manifestEnv()
    )
    let params = rawPlayer.optionalKey("initial_params")
    if not params.isNil:
      for key, value in params.pairs:
        spec.initialParams.add(QueryParam(
          key: key,
          value: value.valueToQueryString()
        ))
    result.add(spec)

proc validateCertificationReferences*(coworld: CoworldPackage) =
  ## Validates Coworld certification references.
  discard coworld.certificationVariant()
  discard coworld.certificationPlayerLaunchSpecs()

proc referencedFilePaths*(coworld: CoworldPackage): seq[(string, string)] =
  ## Returns local files referenced by the manifests.
  let coworldDir = parentDir(coworld.manifestPath)
  if coworld.protocols.player.isLocalManifestUri():
    result.add((
      "Coworld game protocols.player",
      resolveManifestUri(coworldDir, coworld.protocols.player)
    ))
  if coworld.protocols.global.isLocalManifestUri():
    result.add((
      "Coworld game protocols.global",
      resolveManifestUri(coworldDir, coworld.protocols.global)
    ))
  if coworld.protocols.reward.len > 0 and coworld.protocols.reward.isLocalManifestUri():
    result.add((
      "Coworld game protocols.reward",
      resolveManifestUri(coworldDir, coworld.protocols.reward)
    ))

  let clients = coworld.manifest.optionalKey("clients")
  if not clients.isNil and clients.kind == JObject:
    for key in ["player", "global", "replay"]:
      let client = clients.optionalKey(key)
      if not client.isNil and client.kind == JString:
        result.add((
          "Coworld clients." & key,
          resolveManifestUri(coworldDir, client.getStr())
        ))

proc validateReferencedFiles*(coworld: CoworldPackage) =
  ## Raises when a manifest-referenced local file is missing.
  for item in coworld.referencedFilePaths():
    let (label, path) = item
    if not fileExists(path):
      fail(label & " does not exist or is not a file: " & path)

proc addImageReference(
  images: var seq[(string, string)],
  seen: var Table[string, bool],
  label,
  image: string
) =
  ## Adds a Docker image reference once.
  let key = label & "\0" & image
  if not seen.hasKey(key):
    seen[key] = true
    images.add((label, image))

proc imageReferences*(coworld: CoworldPackage): seq[(string, string)] =
  ## Returns Docker images referenced by the Coworld package.
  var seen: Table[string, bool]
  result.addImageReference(seen, "Coworld game image", coworld.cogameImage)
  for slot, player in coworld.certificationPlayerLaunchSpecs():
    result.addImageReference(
      seen,
      "Certification players[" & $slot & "].image",
      player.image
    )

  for section in ["player", "grader", "reporter", "commissioner",
      "diagnoser", "optimizer"]:
    let items = coworld.manifest.optionalKey(section)
    if items.isNil or items.kind != JArray:
      continue
    for i in 0 ..< items.len:
      let item = items[i]
      if item.kind == JObject:
        result.addImageReference(
          seen,
          "Coworld " & section & "[" & $i & "].image",
          item.requireImage("coworld." & section & "[" & $i & "]")
        )

proc runCommandCapture(
  command: string,
  args: openArray[string],
  timeoutSeconds: float
): DockerResult =
  ## Runs one command and captures merged stdout and stderr.
  var process: Process
  try:
    process = startProcess(
      command = command,
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )
    result.code = process.waitForExit(max(1, int(timeoutSeconds * 1000)))
    result.output = process.outputStream().readAll()
  except CatchableError as e:
    fail("could not run " & command & ": " & e.msg)
  finally:
    if not process.isNil:
      try:
        process.close()
      except CatchableError:
        discard

proc runDocker(
  config: ValidatorConfig,
  args: openArray[string],
  timeoutSeconds = 30.0
): DockerResult =
  ## Runs Docker and captures its merged output.
  runCommandCapture(config.dockerBin, args, timeoutSeconds)

proc assertDockerImageReachable*(
  image: string,
  label = "Docker image",
  config = defaultValidatorConfig()
) =
  ## Raises when a Docker image is neither local nor remotely reachable.
  let local = config.runDocker(["image", "inspect", image], 30.0)
  if local.code == 0:
    return
  let remote = config.runDocker(["manifest", "inspect", image], 60.0)
  if remote.code == 0:
    return
  fail(
    label & " is not available locally or reachable remotely: " & image &
      "\ndocker image inspect:\n" & local.output.strip() &
      "\ndocker manifest inspect:\n" & remote.output.strip()
  )

proc validateImageReferences*(
  coworld: CoworldPackage,
  config = defaultValidatorConfig()
) =
  ## Validates all Docker image references in a Coworld package.
  for item in coworld.imageReferences():
    let (label, image) = item
    assertDockerImageReachable(image, label, config)

proc parsePortArg(value: string): int =
  ## Parses one port command argument or returns zero.
  try:
    result = value.parseInt()
  except ValueError:
    result = 0

proc containerPortFromCmd(cmd: JsonNode): int =
  ## Reads a container port from a Docker image command.
  if cmd.kind != JArray:
    return 0
  for i in 0 ..< cmd.len:
    if cmd[i].kind != JString:
      continue
    let arg = cmd[i].getStr()
    if arg.startsWith("--port:"):
      return parsePortArg(arg["--port:".len .. ^1])
    if arg.startsWith("--port="):
      return parsePortArg(arg["--port=".len .. ^1])
    if arg == "--port" and i + 1 < cmd.len and cmd[i + 1].kind == JString:
      return parsePortArg(cmd[i + 1].getStr())

proc dockerImageContainerPort*(dockerBin, image: string): int =
  ## Returns the game container port advertised by a Docker image.
  let res = runCommandCapture(
    dockerBin,
    ["image", "inspect", "--format", "{{json .Config.Cmd}}", image],
    30.0
  )
  if res.code != 0:
    return GamePort
  try:
    result = containerPortFromCmd(parseJson(res.output.strip()))
  except CatchableError:
    result = 0
  if result <= 0:
    result = GamePort

proc loadCoworldPackage*(manifestPath: string): CoworldPackage =
  ## Loads and validates a Coworld package manifest.
  let
    resolvedManifestPath = cleanPath(manifestPath)
    manifest = loadJsonObject(resolvedManifestPath)
  validateCoworldManifest(manifest)

  let
    game = manifest.requireObject("game", "coworld")
    protocols = game.requireObject("protocols", "coworld.game")
  result = CoworldPackage(
    manifestPath: resolvedManifestPath,
    manifest: manifest,
    certification: manifest.requireObject("certification", "coworld"),
    cogameImage: game.requireImage("coworld.game"),
    cogameCommand: game.requireRunCommand("coworld.game"),
    cogameEnv: game.manifestEnv(),
    configSchema: game.requireObject("config_schema", "coworld.game"),
    resultsSchema: game.requireObject("results_schema", "coworld.game"),
    protocols: protocols.protocolDocs()
  )
  result.validateCertificationReferences()
  result.validateReferencedFiles()

proc loadPackageFromManifest*(manifestPath: string): CoworldPackage =
  ## Loads a Coworld package from a manifest path.
  let
    resolved = cleanPath(manifestPath)
    manifest = loadJsonObject(resolved)
  if manifest.isCoworldManifest():
    return loadCoworldPackage(resolved)
  fail("manifest is not a Coworld package: " & resolved)

proc loadPackageFromManifest(
  manifestPath: string,
  criteria: var seq[ValidationCriterion]
): CoworldPackage =
  ## Loads a package and records each manifest criterion.
  let resolved = cleanPath(manifestPath)
  var entryManifest: JsonNode
  try:
    entryManifest = loadJsonObject(resolved)
    criteria.passCriterion("manifest.read", "Manifest file", resolved)
  except CatchableError as e:
    criteria.failCriterion("manifest.read", "Manifest file", e.msg)
    raise

  if entryManifest.isCoworldManifest():
    criteria.passCriterion("manifest.kind", "Manifest type", "Coworld")
  else:
    let message = "manifest is not a Coworld package"
    criteria.failCriterion("manifest.kind", "Manifest type", message)
    fail(message & ": " & resolved)

  let coworldManifest =
    try:
      let loaded = loadJsonObject(resolved)
      validateCoworldManifest(loaded)
      criteria.passCriterion(
        "coworld.schema",
        "Coworld manifest schema",
        resolved
      )
      loaded
    except CatchableError as e:
      criteria.failCriterion(
        "coworld.schema",
        "Coworld manifest schema",
        e.msg
      )
      raise

  let
    game = coworldManifest.requireObject("game", "coworld")
    protocols = game.requireObject("protocols", "coworld.game")
  result = CoworldPackage(
    manifestPath: resolved,
    manifest: coworldManifest,
    certification: coworldManifest.requireObject("certification", "coworld"),
    cogameImage: game.requireImage("coworld.game"),
    cogameCommand: game.requireRunCommand("coworld.game"),
    cogameEnv: game.manifestEnv(),
    configSchema: game.requireObject("config_schema", "coworld.game"),
    resultsSchema: game.requireObject("results_schema", "coworld.game"),
    protocols: protocols.protocolDocs()
  )

  try:
    result.validateCertificationReferences()
    criteria.passCriterion(
      "certification.references",
      "Certification references",
      "variant and player IDs resolve"
    )
  except CatchableError as e:
    criteria.failCriterion(
      "certification.references",
      "Certification references",
      e.msg
    )
    raise

  try:
    result.validateReferencedFiles()
    criteria.passCriterion(
      "referenced.files",
      "Referenced files",
      "protocol docs and client files exist"
    )
  except CatchableError as e:
    criteria.failCriterion("referenced.files", "Referenced files", e.msg)
    raise

proc newWorkspace(prefix = CertPrefix): string =
  ## Creates a new validator workspace.
  let root = repoRoot() / "tmp"
  createDir(root)
  for i in 0 .. 1000:
    var bytes: array[8, byte]
    if not urandom(bytes):
      fail("could not generate workspace id")
    let name = prefix & $getTime().toUnix() & "-" & hexBytes(bytes)
    result = root / name
    if not dirExists(result):
      createDir(result)
      return
  fail("could not create a unique workspace")

proc createEpisodeArtifacts*(workspace = ""): EpisodeArtifacts =
  ## Creates the artifact paths used by one certification run.
  let root =
    if workspace.len > 0:
      cleanPath(workspace)
    else:
      newWorkspace()
  createDir(root)
  let logsDir = root / "logs"
  createDir(logsDir)
  EpisodeArtifacts(
    workspace: root,
    configPath: root / "config.json",
    resultsPath: root / "results.json",
    replayPath: root / "replay.json",
    logsDir: logsDir,
    gameLogPath: logsDir / "game.log"
  )

proc randomToken(): string =
  ## Returns one random token suitable for player authentication.
  var bytes: array[16, byte]
  if not urandom(bytes):
    fail("could not generate player token")
  hexBytes(bytes)

proc schemaAllowsSlotTokens(schema: JsonNode): bool =
  ## Returns true when the config schema supports slots[].token.
  let properties = schema.optionalKey("properties")
  if properties.isNil or properties.kind != JObject:
    return false
  let slots = properties.optionalKey("slots")
  if slots.isNil or slots.kind != JObject:
    return false
  let items = slots.optionalKey("items")
  if items.isNil or items.kind != JObject:
    return false
  let itemProperties = items.optionalKey("properties")
  itemProperties != nil and itemProperties.kind == JObject and
    itemProperties.hasKey("token")

proc injectSlotTokens(config: JsonNode, tokens: openArray[string]) =
  ## Writes runner tokens into existing slot objects.
  if not config.hasKey("slots") or config["slots"].kind != JArray:
    return
  let slots = config["slots"]
  for i in 0 ..< min(slots.len, tokens.len):
    if slots[i].kind == JObject:
      slots[i]["token"] = %tokens[i]

proc buildGameConfig*(coworld: CoworldPackage, tokens: openArray[string]): JsonNode =
  ## Builds and validates the game config used by certification.
  let variant = coworld.certificationVariant()
  result = variant.requireObject("game_config", "coworld.variants").copy()
  let tokenArray = newJArray()
  for token in tokens:
    tokenArray.add(%token)
  result["tokens"] = tokenArray
  if schemaAllowsSlotTokens(coworld.configSchema):
    result.injectSlotTokens(tokens)
  validateJsonSchema(result, coworld.configSchema)

proc episodeRequestPlayer(player: PlayerLaunchSpec): JsonNode =
  ## Converts one launch spec into an episode request player object.
  result = newJObject()
  result["image"] = %player.image
  if player.initialParams.len > 0:
    let params = newJObject()
    for param in player.initialParams:
      params[param.key] = %param.value
    result["initial_params"] = params

proc validateEpisodeRequest*(episodeRequest: JsonNode) =
  ## Validates the generated runner-facing episode request.
  episodeRequest.requireKind(JObject, "episode_request")
  discard episodeRequest.requireObject("game_config", "episode_request")
  let players = episodeRequest.requireArray("players", "episode_request")
  for i in 0 ..< players.len:
    let player = players[i]
    let path = "episode_request.players[" & $i & "]"
    player.requireKind(JObject, path)
    discard player.requireString("image", path)
    let params = player.optionalKey("initial_params")
    if not params.isNil:
      params.requireKind(JObject, path & ".initial_params")
      for key, value in params.pairs:
        discard key
        discard value.valueToQueryString()
  discard episodeRequest.requireString("results_uri", "episode_request")

proc buildEpisodeRequest*(
  coworld: CoworldPackage,
  artifacts: EpisodeArtifacts
): JsonNode =
  ## Builds and validates the runner-facing episode request.
  result = newJObject()
  result["game_config"] =
    coworld.certificationVariant().requireObject(
      "game_config",
      "coworld.variants"
    ).copy()
  let players = newJArray()
  for player in coworld.certificationPlayerLaunchSpecs():
    players.add(episodeRequestPlayer(player))
  result["players"] = players
  result["results_uri"] = %fileUri(artifacts.resultsPath)
  result["replay_uri"] = %fileUri(artifacts.replayPath)
  result["logs_uri"] = %fileUri(artifacts.logsDir)
  validateEpisodeRequest(result)

proc buildPlayerLaunchSpecs*(
  episodeRequest: JsonNode
): seq[PlayerLaunchSpec] =
  ## Builds player launch specs from an episode request.
  validateEpisodeRequest(episodeRequest)
  for player in episodeRequest["players"]:
    var spec = PlayerLaunchSpec(image: player.requireString("image", "player"))
    let params = player.optionalKey("initial_params")
    if not params.isNil:
      for key, value in params.pairs:
        spec.initialParams.add(QueryParam(
          key: key,
          value: value.valueToQueryString()
        ))
    result.add(spec)

proc buildEpisodeRunSpec*(
  coworld: CoworldPackage,
  episodeRequest: JsonNode,
  tokens: openArray[string],
  artifacts: EpisodeArtifacts,
  config: ValidatorConfig,
  containerPort: int
): EpisodeRunSpec =
  ## Builds the Docker episode run spec.
  EpisodeRunSpec(
    cogameImage: coworld.cogameImage,
    cogameCommand: coworld.cogameCommand,
    cogameEnv: coworld.cogameEnv,
    containerPort: containerPort,
    players: coworld.certificationPlayerLaunchSpecs(),
    tokens: @tokens,
    artifacts: artifacts,
    timeoutSeconds: config.timeoutSeconds,
    dockerBin: config.dockerBin
  )

proc freeLocalPort(): int =
  ## Returns an available local TCP port.
  var socket = newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  defer:
    socket.close()
  socket.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = socket.getLocalAddr()
  port.int

proc playerQuery(slot: int, token: string, player: PlayerLaunchSpec): string =
  ## Builds the query string for one player endpoint.
  var params = @[
    QueryParam(key: "slot", value: $slot),
    QueryParam(key: "token", value: token)
  ]
  params.add(player.initialParams)
  queryString(params)

proc playerWsUrl(
  host: string,
  port, slot: int,
  token: string,
  player: PlayerLaunchSpec
): string =
  ## Builds a player WebSocket URL.
  "ws://" & host & ":" & $port & PlayerPath & "?" &
    playerQuery(slot, token, player)

proc httpUrl(port: int, path: string): string =
  ## Builds a local HTTP URL for one container endpoint.
  "http://127.0.0.1:" & $port & path

proc wsUrl(port: int, path: string): string =
  ## Builds a local WebSocket URL for one container endpoint.
  "ws://127.0.0.1:" & $port & path

proc httpStatusCode(status: string): int =
  ## Parses the numeric status code from an HTTP status line.
  let parts = status.strip().splitWhitespace()
  if parts.len == 0:
    return 0
  try:
    result = parts[0].parseInt()
  except ValueError:
    result = 0

proc containerLogs(
  dockerBin,
  containerName: string,
  tail = 200
): string =
  ## Returns recent Docker logs for one container.
  let res = runCommandCapture(
    dockerBin,
    ["logs", "--tail", $tail, containerName],
    10.0
  )
  res.output

proc saveContainerLogs(
  dockerBin,
  containerName,
  path: string
) =
  ## Saves recent Docker logs for one container to disk.
  try:
    writeFile(path, containerLogs(dockerBin, containerName, 1000))
  except CatchableError:
    discard

proc removeContainer(dockerBin, containerName: string) =
  ## Removes a Docker container if it exists.
  discard runCommandCapture(
    dockerBin,
    ["rm", "-f", containerName],
    15.0
  )

proc containerState(
  dockerBin,
  containerName: string
): tuple[running: bool, exitCode: int] =
  ## Returns Docker running state and exit code for one container.
  let res = runCommandCapture(
    dockerBin,
    [
      "inspect",
      "-f",
      "{{.State.Running}} {{.State.ExitCode}}",
      containerName
    ],
    10.0
  )
  if res.code != 0:
    return (false, 1)
  let parts = res.output.strip().splitWhitespace()
  if parts.len >= 2:
    result.running = parts[0] == "true"
    try:
      result.exitCode = parts[1].parseInt()
    except ValueError:
      result.exitCode = 1

proc startDockerContainer(
  dockerBin: string,
  args: openArray[string]
): string =
  ## Starts a detached Docker container and returns its id.
  let res = runCommandCapture(dockerBin, @["run", "-d"] & @args, 30.0)
  if res.code != 0:
    fail("docker run failed: " & res.output.strip())
  res.output.strip()

proc waitForHealth(
  dockerBin,
  containerName: string,
  port: int,
  timeoutSeconds: float
) =
  ## Waits for a game container health endpoint to become ready.
  let deadline = epochTime() + timeoutSeconds
  let url = httpUrl(port, HealthPath)
  while epochTime() < deadline:
    let state = containerState(dockerBin, containerName)
    if not state.running:
      fail(
        "game container exited before healthz passed.\n" &
          containerLogs(dockerBin, containerName)
      )
    var client = newHttpClient(timeout = 1000)
    try:
      let response = client.get(url)
      if httpStatusCode(response.status) == 200:
        return
    except CatchableError:
      discard
    finally:
      client.close()
    sleep(200)
  fail("timed out waiting for " & url & ".\n" &
    containerLogs(dockerBin, containerName))

proc requireWebSocketMessage(url, label: string, timeoutSeconds: float) =
  ## Opens a WebSocket and requires one non-empty message.
  let ws = newWebSocket(url)
  defer:
    ws.close()
  let message = ws.receiveMessage(max(1, int(min(timeoutSeconds, 10.0) * 1000)))
  if message.isNone():
    fail(label & " did not produce a WebSocket message: " & url)
  if message.get().data.len == 0:
    fail(label & " produced an empty WebSocket message: " & url)

proc requireHttpOk(url: string) =
  ## Requires one HTTP endpoint to return a successful status.
  var client = newHttpClient(timeout = 5000)
  try:
    let response = client.get(url)
    let status = httpStatusCode(response.status)
    if status < 200 or status >= 300:
      fail("HTTP endpoint returned " & $status & ": " & url)
  except CogameValidatorError:
    raise
  except CatchableError as e:
    fail("HTTP endpoint failed: " & url & "\n" & e.msg)
  finally:
    client.close()

proc requireBadPlayerRejected(url: string) =
  ## Requires a player WebSocket with a bad token to be rejected.
  try:
    let ws = newWebSocket(url)
    ws.close()
    fail("bad player token was accepted: " & url)
  except CogameValidatorError:
    raise
  except CatchableError:
    discard

proc waitForContainerExit(
  dockerBin,
  containerName,
  label: string,
  timeoutSeconds: float
) =
  ## Waits for a Docker container to stop with exit code zero.
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    let state = containerState(dockerBin, containerName)
    if not state.running:
      if state.exitCode != 0:
        fail(
          label & " container exited with status " & $state.exitCode & ".\n" &
            containerLogs(dockerBin, containerName)
        )
      return
    sleep(250)
  fail("timed out waiting for " & label & " container to exit.\n" &
    containerLogs(dockerBin, containerName))

proc addAiEnvArgs(args: var seq[string]) =
  ## Adds Docker env forwarding args for configured AI keys.
  for name in AiKeyEnvNames:
    if getEnv(name).len > 0:
      args.add("-e")
      args.add(name)

proc gameContainerArgs(
  name: string,
  port: int,
  spec: EpisodeRunSpec
): seq[string] =
  ## Builds Docker arguments for the live game container.
  result = @[
    "--name", name,
    "-p", $port & ":" & $spec.containerPort,
    "-e", HostEnv & "=0.0.0.0",
    "-e", PortEnv & "=" & $spec.containerPort,
    "-e", ConfigEnv & "=file://" & ContainerWorkDir & "/config.json",
    "-e", ResultsEnv & "=file://" & ContainerWorkDir & "/results.json",
    "-e", ReplaySaveEnv & "=file://" & ContainerWorkDir & "/replay.json",
    "-v",
    cleanPath(spec.artifacts.workspace) & ":" & ContainerWorkDir & ":rw"
  ]
  result.addAiEnvArgs()
  for (key, value) in spec.cogameEnv:
    result.add("-e")
    result.add(key & "=" & value)
  result.add(spec.cogameImage)
  for token in spec.cogameCommand:
    result.add(token)

proc replayContainerArgs(
  name: string,
  port: int,
  spec: EpisodeRunSpec
): seq[string] =
  ## Builds Docker arguments for the replay container.
  result = @[
    "--name", name,
    "-p", $port & ":" & $spec.containerPort,
    "-e", HostEnv & "=0.0.0.0",
    "-e", PortEnv & "=" & $spec.containerPort,
    "-e", ReplayLoadEnv & "=file://" & ContainerWorkDir & "/replay.json",
    "-e", ReplayServerEnv & "=1",
    "-v",
    cleanPath(spec.artifacts.workspace) & ":" & ContainerWorkDir & ":rw"
  ]
  result.addAiEnvArgs()
  for (key, value) in spec.cogameEnv:
    result.add("-e")
    result.add(key & "=" & value)
  result.add(spec.cogameImage)
  for token in spec.cogameCommand:
    result.add(token)

proc playerContainerArgs(
  name: string,
  port, slot: int,
  player: PlayerLaunchSpec,
  token: string
): seq[string] =
  ## Builds Docker arguments for one player container.
  result = @[
    "--name", name,
    "--add-host", "host.docker.internal:host-gateway",
    "-e", EngineWsEnv & "=" & playerWsUrl(
      "host.docker.internal",
      port,
      slot,
      token,
      player
    )
  ]
  result.addAiEnvArgs()
  for (key, value) in player.env:
    result.add("-e")
    result.add(key & "=" & value)
  result.add(player.image)
  for token in player.command:
    result.add(token)

proc runCogameEpisode*(spec: EpisodeRunSpec) =
  ## Runs one certified CoGame episode through Docker.
  let
    port = freeLocalPort()
    runId = randomToken()[0 .. 15]
    gameContainer = "coworld-cert-game-" & runId
    replayContainer = "coworld-cert-replay-" & runId
  var playerContainers: seq[string]

  try:
    discard startDockerContainer(
      spec.dockerBin,
      gameContainerArgs(gameContainer, port, spec)
    )
    waitForHealth(
      spec.dockerBin,
      gameContainer,
      port,
      spec.timeoutSeconds
    )

    if spec.players.len > 0:
      requireHttpOk(
        httpUrl(port, PlayerPath) & "?" &
          playerQuery(0, spec.tokens[0], spec.players[0])
      )
      let badUrl = "ws://127.0.0.1:" & $port & PlayerPath &
        "?" & playerQuery(0, "bad", spec.players[0])
      requireBadPlayerRejected(badUrl)
    requireHttpOk(httpUrl(port, GlobalPath))
    requireHttpOk(httpUrl(port, AdminPath))

    for slot, player in spec.players:
      let containerName = "coworld-cert-player-" & runId & "-" & $slot
      playerContainers.add(containerName)
      discard startDockerContainer(
        spec.dockerBin,
        playerContainerArgs(
          containerName,
          port,
          slot,
          player,
          spec.tokens[slot]
        )
      )

    requireWebSocketMessage(
      wsUrl(port, GlobalPath),
      "global viewer",
      spec.timeoutSeconds
    )
    requireWebSocketMessage(
      wsUrl(port, AdminPath),
      "admin viewer",
      spec.timeoutSeconds
    )
    waitForContainerExit(
      spec.dockerBin,
      gameContainer,
      "game",
      spec.timeoutSeconds
    )
    saveContainerLogs(spec.dockerBin, gameContainer, spec.artifacts.gameLogPath)

    for slot, containerName in playerContainers:
      waitForContainerExit(
        spec.dockerBin,
        containerName,
        "player " & $slot,
        10.0
      )
      saveContainerLogs(
        spec.dockerBin,
        containerName,
        spec.artifacts.logsDir / ("player_" & $slot & ".log")
      )

    let replayPort = freeLocalPort()
    discard startDockerContainer(
      spec.dockerBin,
      replayContainerArgs(replayContainer, replayPort, spec)
    )
    waitForHealth(
      spec.dockerBin,
      replayContainer,
      replayPort,
      spec.timeoutSeconds
    )
    let replayQuery = queryString(@[
      QueryParam(key: "uri", value: fileUri(spec.artifacts.replayPath))
    ])
    requireHttpOk(httpUrl(replayPort, ReplayClientPath) & "?" & replayQuery)
    requireWebSocketMessage(
      wsUrl(replayPort, ReplaySocketPath) & "?" & replayQuery,
      "replay viewer",
      spec.timeoutSeconds
    )
  finally:
    saveContainerLogs(spec.dockerBin, gameContainer, spec.artifacts.gameLogPath)
    for slot, containerName in playerContainers:
      saveContainerLogs(
        spec.dockerBin,
        containerName,
        spec.artifacts.logsDir / ("player_" & $slot & ".log")
      )
    saveContainerLogs(
      spec.dockerBin,
      replayContainer,
      spec.artifacts.logsDir / "replay.log"
    )
    for containerName in playerContainers:
      removeContainer(spec.dockerBin, containerName)
    removeContainer(spec.dockerBin, gameContainer)
    removeContainer(spec.dockerBin, replayContainer)

proc loadResults*(
  coworld: CoworldPackage,
  artifacts: EpisodeArtifacts
): JsonNode =
  ## Loads and validates game results from the artifact workspace.
  if not fileExists(artifacts.resultsPath):
    fail("results file was not produced: " & artifacts.resultsPath)
  result = loadJsonObject(artifacts.resultsPath)
  validateJsonSchema(result, coworld.resultsSchema)

proc certifyPackage(
  coworld: CoworldPackage,
  config: ValidatorConfig,
  criteria: var seq[ValidationCriterion]
): CertificationResult =
  ## Certifies an already loaded Coworld package.
  result.coworld = coworld

  if config.checkImages:
    try:
      validateImageReferences(coworld, config)
      criteria.passCriterion(
        "docker.images",
        "Docker images",
        "all referenced images are available"
      )
    except CatchableError as e:
      criteria.failCriterion("docker.images", "Docker images", e.msg)
      result.criteria = criteria
      return
  else:
    criteria.skipCriterion(
      "docker.images",
      "Docker images",
      "disabled by --skip-images"
    )

  var artifacts: EpisodeArtifacts
  try:
    artifacts = createEpisodeArtifacts(config.workspace)
    criteria.passCriterion(
      "artifacts.workspace",
      "Artifact workspace",
      artifacts.workspace
    )
  except CatchableError as e:
    criteria.failCriterion("artifacts.workspace", "Artifact workspace", e.msg)
    result.criteria = criteria
    return
  result.artifacts = artifacts

  var tokens: seq[string]
  for player in coworld.certificationPlayerLaunchSpecs():
    discard player
    tokens.add(randomToken())

  var gameConfig: JsonNode
  try:
    gameConfig = buildGameConfig(coworld, tokens)
    writeFile(artifacts.configPath, gameConfig.pretty())
    criteria.passCriterion(
      "config.schema",
      "Game config schema",
      artifacts.configPath
    )
  except CatchableError as e:
    criteria.failCriterion("config.schema", "Game config schema", e.msg)
    result.criteria = criteria
    return

  var episodeRequest: JsonNode
  try:
    episodeRequest = buildEpisodeRequest(coworld, artifacts)
    criteria.passCriterion(
      "episode.request",
      "Episode request",
      "artifact destinations and players are valid"
    )
  except CatchableError as e:
    criteria.failCriterion("episode.request", "Episode request", e.msg)
    result.criteria = criteria
    return
  result.episodeRequest = episodeRequest

  if config.runContainers:
    let containerPort = dockerImageContainerPort(
      config.dockerBin,
      coworld.cogameImage
    )
    criteria.passCriterion(
      "docker.port",
      "Game container port",
      $containerPort
    )
    try:
      runCogameEpisode(buildEpisodeRunSpec(
        coworld,
        episodeRequest,
        tokens,
        artifacts,
        config,
        containerPort
      ))
      criteria.passCriterion(
        "docker.episode",
        "Docker episode",
        "health, player, global, admin, and replay endpoints passed"
      )
    except CatchableError as e:
      criteria.failCriterion("docker.episode", "Docker episode", e.msg)
      result.criteria = criteria
      return

    try:
      result.results = loadResults(coworld, artifacts)
      criteria.passCriterion(
        "results.schema",
        "Results schema",
        artifacts.resultsPath
      )
    except CatchableError as e:
      criteria.failCriterion("results.schema", "Results schema", e.msg)
      result.criteria = criteria
      return

    if fileExists(artifacts.replayPath):
      criteria.passCriterion("replay.artifact", "Replay artifact", artifacts.replayPath)
    else:
      criteria.failCriterion(
        "replay.artifact",
        "Replay artifact",
        "replay file was not produced: " & artifacts.replayPath
      )
  else:
    result.results = newJObject()
    criteria.skipCriterion(
      "docker.port",
      "Game container port",
      "disabled by --no-run"
    )
    criteria.skipCriterion(
      "docker.episode",
      "Docker episode",
      "disabled by --no-run"
    )
    criteria.skipCriterion(
      "results.schema",
      "Results schema",
      "disabled by --no-run"
    )
    criteria.skipCriterion(
      "replay.artifact",
      "Replay artifact",
      "disabled by --no-run"
    )
  result.criteria = criteria

proc certifyCoworld*(
  manifestPath: string,
  config = defaultValidatorConfig()
): CertificationResult =
  ## Certifies a Coworld manifest and returns produced criteria.
  var criteria: seq[ValidationCriterion]
  try:
    let coworld = loadPackageFromManifest(manifestPath, criteria)
    result = certifyPackage(coworld, config, criteria)
  except CatchableError:
    result.criteria = criteria

proc certifyManifest*(
  manifestPath: string,
  config = defaultValidatorConfig()
): CertificationResult =
  ## Certifies a Coworld manifest and returns produced criteria.
  var criteria: seq[ValidationCriterion]
  try:
    let coworld = loadPackageFromManifest(manifestPath, criteria)
    result = certifyPackage(coworld, config, criteria)
  except CatchableError:
    result.criteria = criteria

proc usage(): string =
  ## Returns command-line usage text.
  """
Usage:
  cogame_validator [options] <manifest>

Options:
  --timeout:<seconds>     Docker and endpoint timeout. Default: 60.
  --workspace:<path>      Artifact workspace. Default: bitworld/tmp.
  --docker:<path>         Docker command. Default: docker or env override.
  --skip-images           Skip Docker image inspect checks.
  --no-run                Validate manifests and write config only.
  --help                  Show this help.

The manifest must be coworld_manifest.json.
"""

proc parseFloatOption(value, option: string): float =
  ## Parses one float command-line option.
  try:
    result = value.parseFloat()
  except ValueError:
    fail(option & " must be a number")

proc parseArgs(): tuple[manifestPath: string, config: ValidatorConfig] =
  ## Parses command-line options.
  result.config = defaultValidatorConfig()
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if result.manifestPath.len > 0:
        fail("only one manifest path may be provided")
      result.manifestPath = key
    of cmdLongOption:
      case key
      of "":
        discard
      of "timeout":
        result.config.timeoutSeconds = parseFloatOption(val, "--timeout")
      of "workspace":
        result.config.workspace = val
      of "docker":
        result.config.dockerBin = val
      of "skip-images":
        result.config.checkImages = false
      of "no-run":
        result.config.runContainers = false
      of "help":
        echo usage()
        quit(0)
      else:
        fail("unknown option: --" & key)
    of cmdShortOption:
      case key
      of "h":
        echo usage()
        quit(0)
      else:
        fail("unknown option: -" & key)
    of cmdEnd:
      discard
  if result.manifestPath.len == 0:
    echo usage()
    quit(1)

proc statusName(status: CriterionStatus): string =
  ## Returns the display label for one criterion status.
  case status
  of CriterionPass:
    result = "PASS"
  of CriterionFail:
    result = "FAIL"
  of CriterionSkip:
    result = "SKIP"

proc printCriteria(criteria: openArray[ValidationCriterion]) =
  ## Prints criteria in a command-line friendly format.
  for criterion in criteria:
    var line = "[" & statusName(criterion.status) & "] " & criterion.id
    line.add(" - " & criterion.name)
    if criterion.message.len > 0:
      line.add(": " & criterion.message)
    echo line

proc runCli*() =
  ## Runs the command-line validator.
  try:
    let (manifestPath, config) = parseArgs()
    let result = certifyManifest(manifestPath, config)
    echo "Validation criteria:"
    printCriteria(result.criteria)
    if result.coworld.manifestPath.len > 0:
      echo "Coworld: ", result.coworld.manifestPath
    if result.artifacts.workspace.len > 0:
      echo "Artifacts: ", result.artifacts.workspace
      echo "Results: ", result.artifacts.resultsPath
      echo "Replay: ", result.artifacts.replayPath
      echo "Logs: ", result.artifacts.logsDir
    if not result.validationPassed():
      quit(1)
  except CogameValidatorError as e:
    stderr.writeLine("cogame validator failed: " & e.msg)
    quit(1)
  except CatchableError as e:
    stderr.writeLine("cogame validator failed: " & e.msg)
    quit(1)

when isMainModule:
  runCli()
