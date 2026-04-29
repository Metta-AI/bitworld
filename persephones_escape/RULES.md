# Persephone's Escape — Game Rules

Based on Two Rooms and a Boom, themed around the myth of Persephone.

## Teams and Roles

| Role | Team | Description |
|------|------|-------------|
| Hades | Shades | Wants to be in the same room as Persephone at game end |
| Persephone | Nymphs | Wants to be in a different room from Hades at game end |
| Cerberus | Shades | Engineer — Hades must mutually card-share with Cerberus for Shades to win |
| Demeter | Nymphs | Doctor — Persephone must mutually card-share with Demeter for Nymphs to win |
| Shades (grunt) | Shades | No special ability, wins with team |
| Nymphs (grunt) | Nymphs | No special ability, wins with team |
| Gambler | Neutral | Assigned when odd player count (NOT YET FULLY IMPLEMENTED — see below) |

## Setup

```
require MIN_PLAYERS (6)
assign roles:
  1 Hades (Shades)
  1 Persephone (Nymphs)
  1 Cerberus (Shades)
  1 Demeter (Nymphs)
  if odd players: 1 Gambler (neutral)
  remaining split evenly: half Shades grunts, half Nymphs grunts
shuffle players randomly into Underworld and Mortal Realm (roughly equal)
randomly select one leader per room
show each player their role card (intro screen with role, team, room, controls)
```

## Round Loop (3 rounds)

Round durations: currently 15s each (testing values).

### During Each Round

- Players move freely within their room (rooms are completely disjoint — no crossing)
- Players may chat (scoped to nearby bubble radius)
- Players can interact via the menu (B button when not near another player)

### Card Sharing (via menu)

| Action | Effect |
|--------|--------|
| CARD-LOCAL | Show your full card (role + team) to nearby players |
| COLOR-LOCAL | Show only your team color to nearby players |
| CARD-ALL | Show your full card to entire room |
| COLOR-ALL | Show only your team color to entire room |
| OFFER | Offer a committed mutual card exchange to nearest player |
| ACCEPT | Accept a pending mutual share offer (both cards revealed simultaneously) |

- Offers expire after 10 seconds
- A blinking indicator appears above a player who has an offer directed at you
- Players may lie verbally but shared cards are always truthful
- Mutual shares are the only way to satisfy Cerberus/Demeter win conditions

### Leadership

- Each room always has exactly one leader (randomly assigned at round start)
- **PASS** — leader may offer leadership to a nearby player (target must accept within 10 seconds)
- **USURP** — any non-leader may vote for themselves or another player via menu; if a candidate gets majority votes, they become leader
- Usurp votes are visible in the global viewer's room panels

### Hostage Selection (after round timer expires)

```
leader of each room selects hostages to send to the other room
hostage count per round (by total player count):
  6-10 players:  [1, 1, 1]
  11-21 players: [1, 1, 2]
  22+ players:   [1, 2, 3]
rules:
  leaders CANNOT be selected as hostages
  leader uses left/right to pick, A to toggle, Select to commit
  15-second timeout: uncommitted selections auto-filled randomly
```

### Hostage Exchange

Selected hostages are teleported to the other room. Brief cutscene transition (3 seconds).

## Game End (after round 3)

### Win Condition Decision Tree

```
Hades and Persephone in SAME room?
├── YES: Did Hades mutually share with Cerberus?
│   ├── YES → Shades win
│   └── NO: Did Persephone mutually share with Demeter?
│       ├── YES → Nymphs win
│       └── NO → Nobody wins
└── NO: Did Persephone mutually share with Demeter?
    ├── YES → Nymphs win
    └── NO: Did Hades mutually share with Cerberus?
        ├── YES → Shades win
        └── NO → Nobody wins
```

- "Mutually share" means both players used the OFFER/ACCEPT mechanic (both in each other's `revealedTo` set)
- If neither key role fulfilled their card-share obligation, nobody wins
- All roles are revealed for 5 seconds, then game returns to lobby after 10 seconds

## Controls

| Key | Action |
|-----|--------|
| WASD / Arrows | Move |
| A (K) | Action / Select menu item |
| B (J) | Open menu / Close menu / Reveal card (near player) |
| Select (L) | Commit hostage selection (leader) |
| Enter | Chat |

## Known Gaps / Not Yet Implemented

1. **Gambler role is incomplete** — The role is assigned for odd player counts but there is no GamblerChoice phase. The Gambler currently cannot pick a side and cannot win. Consider either implementing the full mechanic (choice phase + independent win) or removing the role entirely.
2. **Exchange animation is minimal** — Rooms are disjoint, so the exchange is a text-only cutscene showing departing hostages. No walking animation.
3. **Round durations are testing values** — All rounds are 15 seconds instead of the standard 3min/2min/1min.

## Design Differences from Standard 2R1B

1. **Disjoint rooms** — rooms are completely separate coordinate spaces with no physical connection. The global viewer renders them side by side.
2. **Random leader selection** — leaders are randomly assigned each round (can be passed or usurped).
3. **Bubble-scoped chat** — speech is only heard by nearby players within a radius, not the whole room.
4. **Card sharing via menu** — instead of physical card showing, players use menu actions.
5. **Mandatory card-share for victory** — Cerberus and Demeter create a requirement that the key roles (Hades/Persephone) must engage in mutual card sharing for their team to win. Without this, nobody wins.
