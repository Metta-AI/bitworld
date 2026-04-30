import WebSocket from "ws";
import { argv } from "process";
import {
  TARGET_FPS, PLAYER_W, PLAYER_H, BUBBLE_RADIUS, ROOM_W,
  BUTTON_A, BUTTON_B, BUTTON_SELECT,
} from "./constants.js";
import { Room } from "./types.js";
import {
  sendInput, sendChat, PACKED_FRAME_BYTES, unpackFrame,
  ActionQueue, menuSequence, hostageSelectSequence,
  moveToward, randomDir, randomPoint, distTo, isNearby,
  type Point,
} from "./bot_utils.js";

const count = parseInt(argv[2] ?? "6");
const url = argv[3] ?? "ws://localhost:8080/player";

// ---------------------------------------------------------------------------
// Bot state
// ---------------------------------------------------------------------------

interface BotState {
  name: string;
  ws: WebSocket;
  tick: number;
  frame: Uint8Array | null;
  actions: ActionQueue;
  wanderTarget: Point | null;
  wanderTicks: number;
  menuCooldown: number;
  shareCooldown: number;
  phase: "idle" | "wander" | "approach" | "menu";
  approachTarget: number; // player index to walk toward
}

// ---------------------------------------------------------------------------
// Main bot logic — called once per received frame
// ---------------------------------------------------------------------------

function botStep(bot: BotState) {
  bot.tick++;

  // Drain any queued action sequence first
  if (!bot.actions.empty) {
    sendInput(bot.ws, bot.actions.shift()!);
    return;
  }

  if (bot.menuCooldown > 0) bot.menuCooldown--;
  if (bot.shareCooldown > 0) bot.shareCooldown--;

  // Every 2 seconds, try hostage-select actions (only leaders respond)
  if (bot.tick % (TARGET_FPS * 2) === 0) {
    doHostageSelect(bot);
    if (!bot.actions.empty) {
      sendInput(bot.ws, bot.actions.shift()!);
      return;
    }
  }

  // Periodically open menu and do something useful
  if (bot.menuCooldown <= 0 && Math.random() < 0.06) {
    doMenuAction(bot);
    if (!bot.actions.empty) {
      sendInput(bot.ws, bot.actions.shift()!);
      return;
    }
  }

  // Wander: pick a random point and walk toward it
  if (bot.wanderTarget === null || bot.wanderTicks <= 0) {
    bot.wanderTarget = randomPoint(Room.RoomA); // room doesn't matter for point generation
    bot.wanderTicks = 15 + Math.floor(Math.random() * 40);
  }

  bot.wanderTicks--;

  // Mix in some approach-other-player behavior to get into bubble range
  if (Math.random() < 0.15) {
    // Pick a random "other player index" to approach — we don't have server
    // state, so we just walk in a random direction for a bit. The smart_bots
    // running inside the server could use sim state, but these are websocket
    // clients working from frames alone. Just wander toward random points.
    bot.wanderTarget = randomPoint(Room.RoomA);
    bot.wanderTicks = 10 + Math.floor(Math.random() * 20);
  }

  const myX = ROOM_W / 2;
  const myY = ROOM_W / 2;
  const mask = moveToward(myX, myY, bot.wanderTarget.x, bot.wanderTarget.y);
  sendInput(bot.ws, mask || randomDir());
}

// ---------------------------------------------------------------------------
// Menu interactions — share cards, offer trades, vote usurp, etc.
// ---------------------------------------------------------------------------

function doMenuAction(bot: BotState) {
  bot.menuCooldown = TARGET_FPS * 3;

  const roll = Math.random();

  if (roll < 0.3) {
    // A creates chatroom directly
    bot.actions.push(BUTTON_A, 0);
  } else if (roll < 0.5) {
    // SELECT opens comm menu, A selects SHOUT (index 0)
    bot.actions.push(...menuSequence("comm", "SHOUT", ["SHOUT", "INFO"]));
  } else if (roll < 0.7) {
    // B opens info screen directly
    bot.actions.push(BUTTON_B, 0);
  } else {
    // SELECT opens comm menu, A selects SHOUT, then navigate usurp and A votes
    bot.actions.push(...menuSequence("comm", "SHOUT", ["SHOUT", "INFO"]));
    const moves = Math.floor(Math.random() * 4);
    for (let i = 0; i < moves; i++) bot.actions.push(0x08, 0); // RIGHT
    bot.actions.push(BUTTON_A, 0);
    bot.actions.push(BUTTON_SELECT, 0); // close global chat
  }
}

// ---------------------------------------------------------------------------
// Hostage selection — pick random hostages and commit
// ---------------------------------------------------------------------------

function doHostageSelect(bot: BotState) {
  // Open global chat (via comm menu SHOUT), pick hostages, commit
  const seq: number[] = [];
  seq.push(...menuSequence("comm", "SHOUT", ["SHOUT", "INFO"]));
  const picks = 1 + Math.floor(Math.random() * 2);
  for (let i = 0; i < picks; i++) {
    const moves = 1 + Math.floor(Math.random() * 3);
    for (let j = 0; j < moves; j++) {
      seq.push(Math.random() < 0.5 ? 0x04 : 0x08); // LEFT or RIGHT
      seq.push(0);
    }
    seq.push(BUTTON_A, 0); // toggle
  }
  seq.push(BUTTON_B, 0); // commit
  seq.push(BUTTON_SELECT, 0); // close global chat
  bot.actions.push(...seq);
}

// ---------------------------------------------------------------------------
// Boot up bots
// ---------------------------------------------------------------------------

const bots: BotState[] = [];

for (let i = 0; i < count; i++) {
  const name = `bot_${i + 1}`;
  const ws = new WebSocket(`${url}?name=${name}`, { perMessageDeflate: false });

  const bot: BotState = {
    name, ws,
    tick: 0,
    frame: null,
    actions: new ActionQueue(),
    wanderTarget: null,
    wanderTicks: 0,
    menuCooldown: Math.floor(Math.random() * TARGET_FPS * 3), // stagger initial menus
    shareCooldown: 0,
    phase: "idle",
    approachTarget: -1,
  };

  ws.on("open", () => console.log(`${name} connected`));

  ws.on("message", (data: Buffer) => {
    if (data.length === PACKED_FRAME_BYTES) {
      bot.frame = unpackFrame(data);
      botStep(bot);
    }
  });

  ws.on("close", () => console.log(`${name} disconnected`));
  ws.on("error", (err) => console.error(`${name} error:`, err.message));

  bots.push(bot);
}

process.on("SIGINT", () => {
  for (const bot of bots) bot.ws.close();
  process.exit(0);
});

console.log(`Connecting ${count} smart bots to ${url}...`);
