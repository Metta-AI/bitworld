import
  std/os,
  zippy,
  bitworld/replays

const
  NameSpec = ReplaySpec(
    magic: "BITWORLD",
    formatVersion: 4'u16,
    gameName: "test_game",
    gameVersion: "1",
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )
  AddressSpec = ReplaySpec(
    magic: "BITWORLD",
    formatVersion: 3'u16,
    gameName: "address_game",
    gameVersion: "1",
    joinKind: rjkAddress,
    allowChat: false,
    allowCompressed: true,
    hashOrder: rhoError
  )

proc testNameSlotTokenReplay() =
  ## Tests the name, slot, token replay join shape.
  let path = getTempDir() / "bitworld-test-name-replay.bitreplay"
  let debugPacket = @[1'u8, 2, 3, 4]
  var writer = openReplayWriter(path, """{"seed":1}""", NameSpec)
  writer.writeJoin(10'u32, 0, "alice", 3, "token")
  writer.writeInput(ReplayInput(time: 20'u32, player: 0, keys: 5))
  writer.writeChat(30'u32, 0, "hello")
  writer.writeDebugSprite(35'u32, 0, debugPacket)
  writer.writeClientInput(40'u32, 1, @[0x82'u8, 0x40, 0x01, 0xc8, 0x00])
  writer.writeHash(2'u32, 0x1234'u64)
  writer.closeReplayWriter()

  let
    bytes = readFile(path)
    data = loadReplay(path, NameSpec)
    compressedData = parseReplayBytes(compress(bytes), NameSpec)
  doAssert data.gameName == "test_game"
  doAssert data.configJson == """{"seed":1}"""
  doAssert data.joins[0].name == "alice"
  doAssert data.joins[0].slot == 3
  doAssert data.joins[0].token == "token"
  doAssert data.inputs[0].keys == 5
  doAssert data.chats[0].message == "hello"
  doAssert data.debugSprites[0].time == 35'u32
  doAssert data.debugSprites[0].player == 0'u8
  doAssert data.debugSprites[0].packet == debugPacket
  doAssert data.hashes[0].hash == 0x1234'u64
  doAssert data.clientInputs[0].time == 40'u32
  doAssert data.clientInputs[0].player == 1'u8
  doAssert data.clientInputs[0].packet ==
    @[0x82'u8, 0x40, 0x01, 0xc8, 0x00]
  doAssert compressedData.joins[0].name == "alice"
  doAssert compressedData.debugSprites[0].packet == debugPacket
  doAssert compressedData.clientInputs[0].packet ==
    data.clientInputs[0].packet
  removeFile(path)

proc testAddressReplay() =
  ## Tests the address replay join shape.
  let path = getTempDir() / "bitworld-test-address-replay.bitreplay"
  var writer = openReplayWriter(path, "{}", AddressSpec)
  writer.writeJoin(10'u32, 0, "127.0.0.1:1234")
  writer.writeLeave(20'u32, 0)
  writer.writeHash(1'u32, 7'u64)
  writer.closeReplayWriter()

  let data = loadReplay(path, AddressSpec)
  doAssert data.joins[0].address == "127.0.0.1:1234"
  doAssert data.joins[0].name == data.joins[0].address
  doAssert data.leaves[0].player == 0'u8
  doAssert data.hashes[0].tick == 1'u32
  removeFile(path)

echo "Testing replay codec"
doAssert tickTime(24, 24) == 1000'u32
for fps in [12, 24, 60]:
  for tick in 0 ..< 10_000:
    doAssert timeTick(tickTime(tick, fps), fps) == tick
testNameSlotTokenReplay()
testAddressReplay()
echo "All tests passed"
