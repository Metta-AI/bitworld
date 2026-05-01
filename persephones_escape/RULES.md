# Persephone's Escape — Game Rules

Based on Two Rooms and a Boom, themed around the myth of Persephone.

## Teams and Roles

| Role | Team | Description |
|------|------|-------------|
| Hades | Shades | Wants to be in the same room as Persephone at game end |
| Persephone | Nymphs | Wants to be in a different room from Hades at game end |
| Cerberus | Shades | Hades must perform a mutual role exchange with Cerberus for Shades to win |
| Demeter | Nymphs | Persephone must perform a mutual role exchange with Demeter for Nymphs to win |
| Shades (grunt) | Shades | No special ability, wins with team |
| Nymphs (grunt) | Nymphs | No special ability, wins with team |

## Setup

```
require MIN_PLAYERS (6)
assign roles:
  1 Hades (Shades)
  1 Persephone (Nymphs)
  1 Cerberus (Shades)
  1 Demeter (Nymphs)
  remaining split evenly: half Shades grunts, half Nymphs grunts
shuffle players randomly into Underworld and Mortal Realm (roughly equal)
randomly select one leader per room
show each player their role card (intro screen with role, team, room, controls)
```

## Round Loop (3 rounds)

Round durations: currently 15s each (testing values).

### During Each Round

- Players move freely within their room (rooms are completely disjoint — no crossing)
- Players communicate via private chatrooms or global room chat
- Players can reveal information and exchange roles inside chatrooms

### Information Sharing (inside chatrooms)

| Action | Type | Effect |
|--------|------|--------|
| C.OFFER / C.ACCPT | Mutual color | Both players consent to reveal team colors to each other |
| ROLE | One-way | Show your full role card to all chatroom occupants |
| R.OFFER / R.ACCPT | Mutual role | Both players consent to exchange roles — both full roles revealed to each other |

- One-way reveals (ROLE) and color exchanges let others see information but do NOT count for the win condition
- Only mutual role exchange (R.OFFER/R.ACCPT) satisfies the Cerberus/Demeter requirement
- Players may lie verbally but revealed cards/colors are always truthful
- Offers can be withdrawn before acceptance

### Leadership

- Each room always has exactly one leader (randomly assigned each round)
- **PASS / TAKE** — leader may offer leadership inside a chatroom; target must accept
- **USURP** — any non-leader may vote via global chat; if a candidate gets majority votes from the room, they become leader
- Usurp votes are visible in the global viewer's room panels

### Hostage Selection (after round timer expires)

```
leader of each room selects hostages to send to the other room
hostage count: configured per round (default: 1 per round)
rules:
  leaders CANNOT be selected as hostages
  leader uses left/right to pick, A to toggle, Select to commit
  15-second timeout: uncommitted selections auto-filled randomly
  exchanged players have their usurp votes reset
```

### Hostage Exchange

Selected hostages are teleported to the other room. Brief cutscene transition (3 seconds).

## Game End (after final round)

### Win Condition Decision Tree

```
Hades and Persephone in SAME room?
├── YES: Did Hades exchange roles with Cerberus?
│   ├── YES -> Shades win
│   └── NO: Did Persephone exchange roles with Demeter?
│       ├── YES -> Nymphs win
│       └── NO -> Nobody wins
└── NO: Did Persephone exchange roles with Demeter?
    ├── YES -> Nymphs win
    └── NO: Did Hades exchange roles with Cerberus?
        ├── YES -> Shades win
        └── NO -> Nobody wins
```

- "Exchange cards" means both players used the OFFER/ACCEPT mechanic (tracked via `sharedWith` set — distinct from one-way reveals)
- If neither key role fulfilled their role exchange, nobody wins
- All roles are revealed for 5 seconds, then game stays on the results screen for 10 seconds before returning to lobby

## Design Differences from Standard 2R1B

1. **Disjoint rooms** — rooms are completely separate coordinate spaces with no physical connection. The global viewer renders them side by side.
2. **Random leader selection** — leaders are randomly assigned each round (can be passed or usurped).
3. **Chatroom-based communication** — players create private chatrooms to talk and share information, rather than physical card showing.
4. **Global room chat** — a room-wide text channel for public communication and usurp voting.
5. **Mandatory role exchange for victory** — Cerberus and Demeter create a requirement that the key roles (Hades/Persephone) must perform a consensual mutual role exchange for their team to win. Without this, nobody wins.

## See Also

- [GUIDE.md](GUIDE.md) — interface and controls reference
