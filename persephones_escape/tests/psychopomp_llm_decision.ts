import assert from "node:assert/strict";
import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";
import { PlayerShape, Room } from "../game/types.js";
import { createGameKnowledge, type PlayerKnowledge } from "../bots/game_knowledge.js";
import { decidePsychopomps } from "../bots/skills.js";

function candidate(name: string, color: number, shape: PlayerShape, room: Room, knownTeam: string | null = null): PlayerKnowledge {
  return {
    name,
    color,
    shape,
    lastRoom: room,
    lastPos: null,
    lastSeenTick: 0,
    knownRole: null,
    knownTeam,
    isLeader: false,
    inWhisper: false,
    positionAmbiguousByColor: false,
    weSharedWith: false,
    theyRevealedCard: false,
    theyRevealedColor: false,
  };
}

const knowledge = createGameKnowledge("psychopomp_llm_test");
knowledge.myCharName = "R.CRCL";
knowledge.myRoom = Room.RoomA;
knowledge.matchFacts.currentRound = 1;
knowledge.matchFacts.rounds = [{ round: 1, durationSecs: 60, psychopomps: 1 }];
knowledge.self.name = "R.CRCL";
knowledge.self.room = Room.RoomA;
knowledge.self.amLeader = true;

knowledge.players.set("R.CRCL", candidate("R.CRCL", 3, PlayerShape.Circle, Room.RoomA, "TeamA"));
knowledge.players.set("B.SQR", candidate("B.SQR", 14, PlayerShape.Square, Room.RoomA, "TeamA"));
knowledge.players.set("Y.TRI", candidate("Y.TRI", 8, PlayerShape.Triangle, Room.RoomA, null));
knowledge.players.set("G.DMOND", candidate("G.DMOND", 10, PlayerShape.Diamond, Room.RoomA, "TeamB"));

let capturedSystem = "";
let capturedUser = "";
const fakeBedrock = {
  async send(command: any) {
    capturedSystem = command.input.system?.[0]?.text ?? "";
    capturedUser = command.input.messages?.[0]?.content?.[0]?.text ?? "";
    return {
      output: {
        message: {
          content: [{ text: `["B.SQR"]` }],
        },
      },
    };
  },
} as unknown as BedrockRuntimeClient;

const chosen = await decidePsychopomps({
  bedrock: fakeBedrock,
  modelId: "fake-psychopomp-model",
  botName: "psychopomp_llm_test",
}, knowledge);

assert.deepEqual(chosen, ["B.SQR"], "psychopomp LLM decision should accept a concrete valid target");
assert.match(capturedSystem, /Return only a JSON array/);
assert.match(capturedSystem, /any in-room non-self candidate can be a valid psychopomp/);
assert.doesNotMatch(capturedSystem, /Prefer known enemies/);
assert.match(capturedUser, /Need 1/);
assert.match(capturedUser, /B\.SQR/);
assert.match(capturedUser, /Y\.TRI/);
assert.match(capturedUser, /G\.DMOND/);

if (process.env.RUN_BEDROCK_PSYCHOPOMP_LIVE === "1") {
  const live = await decidePsychopomps({
    bedrock: new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? "us-west-2" }),
    modelId: process.env.BEDROCK_MODEL_ID ?? "us.anthropic.claude-sonnet-4-6",
    botName: "psychopomp_llm_live_test",
  }, knowledge);
  assert.ok(live && live.length === 1, `live LLM should choose one target, got ${JSON.stringify(live)}`);
  assert.ok(["B.SQR", "Y.TRI", "G.DMOND"].includes(live[0]), `live LLM chose invalid target ${JSON.stringify(live)}`);
}

console.log("psychopomp LLM decision test passed");
