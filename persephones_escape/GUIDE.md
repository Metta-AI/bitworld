# Persephone's Escape — Interface Guide

How to play the game using the 128x128 pixel client. See RULES.md for game rules and win conditions.

## Controls Overview

| Key | Keyboard | Gamepad |
|-----|----------|---------|
| Move | WASD / Arrows | D-pad |
| A (action) | J | A |
| B (info) | K | B |
| Select | L | Select |
| Chat | Enter | - |

## Game World

The main view shows your character in a top-down room with fog of war. A minimap in the top-right corner shows visible players as colored dots (you are always white).

### Bottom Bar

The bottom bar shows context-sensitive hints:

- **Default**: `J:COMM  K:INFO  L:GLOBAL` — your three main actions
- **Waiting for chatroom entry**: `WAITING...` with blinking unread dot if global messages exist
- **Comm menu open**: `< START >` or `< REQUEST >` — navigate with left/right, B to select
- **Leader in hostage select**: `L:COMMIT  </>:PICK  J:TOG`

### A Button — Communication Menu

Press A to open the comm menu. Navigate with left/right, press B to select, A to cancel.

| Item | When Available | Effect |
|------|---------------|--------|
| START | Always | Create a private chatroom at your position |
| REQUEST | Near a player who is in a chatroom | Request entry to their chatroom |
| SHOUT | Always | Open the global room chat |

### B Button — Info Screen

Press B to toggle the shared info screen. This shows all players whose identity you know:

- **Full role revealed**: sprite + role indicator + role name in team color
- **Color only revealed**: sprite + team color dot + "???"
- **You** always appear first

If the list is longer than the screen, use up/down to scroll. A scroll indicator appears on the right edge. Press any button (A/B/Select) to close.

### Select Button — Global Chat

Press Select to open global chat (or commit hostage selections if you are the leader during hostage select phase).

## Private Chatrooms

When you create or enter a chatroom, your view switches to a full-screen chat interface. Your character stays in the world with a speech bubble indicator above it (visible to other players).

### Chatroom Layout

```
Top bar:    CHAT  [sprite][sprite]...     (participants)
Messages:   Colored dots = sender color
            * prefix = system messages
Entry req:  [!] [sprite] WANTS IN        (if someone is requesting)
Bottom bar: Action context (see below)
```

### A Button — Exit

Press A to leave the chatroom and return to the game world.

### B Button — Action Menu

Press B to open the action menu. Navigate with left/right, press B to confirm, A to cancel.

| Action | When Shown | Effect |
|--------|------------|--------|
| C.OFFER | Not currently offering color | Offer to mutually reveal team colors |
| C.UNOFFR | Currently offering color | Withdraw your color exchange offer |
| C.ACCPT | Another occupant offered color | Accept a color offer — opens target picker |
| ROLE | Always | One-way: show your full role card to all occupants |
| R.OFFER | Not currently offering role | Offer mutual role exchange |
| R.UNOFFR | Currently offering role | Withdraw your role exchange offer |
| R.ACCPT | Another occupant offered role | Accept a role offer — opens target picker |
| PASS | You are the room leader | Offer leadership to the room |
| TAKE | Another occupant offered leadership | Accept leadership transfer |
| GRANT | Someone is requesting entry | Let the first requester into the chatroom |
| EXIT | Always | Leave the chatroom |

### Color Exchange (C.OFFER / C.ACCPT)

A safe first step to verify someone's team without revealing your role:

1. Player A selects **C.OFFER**. System message: "offers color"
2. Player B sees **C.ACCPT** appear in their action menu
3. Player B selects **C.ACCPT**, then picks Player A's sprite from the target picker (left/right to navigate, B to confirm, A to cancel)
4. Both players' team colors are revealed to each other. System message: "colors exchanged!"

Either player can withdraw before acceptance by selecting **C.UNOFFR**. Offers are cleared when a player leaves the chatroom.

### Role Exchange (R.OFFER / R.ACCPT)

This is the core mechanic for the win condition. It requires consent from both players:

1. Player A selects **R.OFFER**. System message: "offers to share"
2. Player B sees **R.ACCPT** appear in their action menu
3. Player B selects **R.ACCPT**, then picks Player A's sprite from the target picker (left/right to navigate, B to confirm, A to cancel)
4. Both players' full roles are revealed to each other. System message: "roles exchanged!"

Either player can withdraw before acceptance by selecting **R.UNOFFR**. Offers are cleared when a player leaves the chatroom.

One-way reveals (ROLE) and color exchanges do NOT count for the win condition — only mutual role exchange does.

### Up/Down — Scroll Messages

Scroll through chat history with up/down.

### Enter — Type Message

Type a message visible to all current chatroom occupants. Only occupants present when a message is sent can see it.

## Global Chat

A room-wide text chat accessible from anywhere via the comm menu (SHOUT) or the Select button.

### Layout

```
Top bar:    [ROOM NAME] CHAT
Messages:   Scrollable message history
Bottom bar: Usurp candidate selector (if non-leader)
            or "J:CLOSE  ENTER:TYPE" (if leader)
```

### A Button — Close

Press A to close global chat and return to the game world.

### B Button — Vote Usurp

If you are not the room leader, the bottom bar shows the current usurp candidate. Use left/right to navigate candidates (player sprites or NONE/ME), then press B to cast your vote.

### Up/Down — Scroll Messages

Scroll through message history. You only see messages sent after you entered the room.

### Enter — Type Message

Send a message to everyone in your room.

## Phase-Specific Interfaces

### Role Reveal (game start)

A bordered screen showing your role, team, and room assignment with a countdown timer. Controls are listed on screen. Dismisses automatically when the timer expires.

### Hostage Select (end of each round)

- **Leaders**: Use left/right to move cursor across eligible players, A to toggle selection, Select (L) to commit. 15-second timeout auto-fills remaining picks.
- **Non-leaders**: See the leader's name and countdown timer. Can still access chatrooms and global chat while waiting.

### Hostage Exchange

A brief cutscene (3 seconds) showing hostages being transferred between rooms. No input during this phase.

### Reveal (game end)

All roles are revealed. The winning team (or "NO ONE WINS") is displayed. Returns to lobby after a few seconds.

## Visual Indicators

| Indicator | Meaning |
|-----------|---------|
| Crown pixels above sprite | Room leader |
| Speech bubble above sprite | Player is in a chatroom |
| Blinking "?" above sprite | Player is waiting to enter a chatroom |
| Blinking dot (bottom-right) | Unread global chat messages |
| Role indicator bar below sprite | Colored bar showing team; special dots for key roles |
