# Reward Spec

Reward Spec is a small text websocket protocol for streaming per-player reward
data from a Bitworld simulation.

The client connects to a websocket endpoint. The usual path is:

```text
/reward
```

The protocol uses text websocket messages. The server sends one text message for
every simulation tick.

## Packet Format

Each message is a newline separated packet. Each non-empty line starts with a
name, followed by one or more space separated fields.

```text
player 127.0.0.1 54002
reward reward 1.0
```

The packet format is ASCII compatible UTF-8 text. Lines end with `\n`. A sender
may use `\r\n`. A receiver should ignore empty lines.

## Lines

### Player

Identifies the player that the following reward values belong to.

```text
player <address> <port>
```

| Field | Type | Notes |
| --- | --- | --- |
| Name | `string` | Must be `player` |
| Address | `string` | Player address |
| Port | `u16` | Player port |

`Address` must not contain spaces. `Port` is written in base 10.

### Reward

Sends one named reward value for the current player and tick.

```text
reward <name> <value>
```

| Field | Type | Notes |
| --- | --- | --- |
| Name | `string` | Must be `reward` |
| Reward name | `string` | Name of the value |
| Value | `float` | Reward value |

The current required reward name is:

| Reward name | Meaning |
| --- | --- |
| `reward` | Reward used for training |

The server must send `reward reward <value>` for each player in each tick
packet. The value is written as a base 10 floating point number.

## Multiple Players

A packet may contain reward data for multiple players. Each player block starts
with a `player` line. Reward lines after a `player` line belong to that player
until the next `player` line.

```text
player 127.0.0.1 54002
reward reward 1.0
player 127.0.0.1 54003
reward reward -0.25
```

Reward lines before the first player line are invalid.

## Future Values

Future versions may add more reward names after the `reward` line name. Useful
examples include:

```text
reward advantage 0.4
reward steps 12
```

A receiver must read `reward reward <value>`. A receiver should ignore reward
names it does not understand.

## Message Rules

A server-to-client text message is one reward packet for one simulation tick.

The server should send packets in simulation tick order. If no players are
connected, the server may send an empty packet or skip the tick.

Client-to-server messages are not used by this protocol.

Binary websocket messages are invalid in this version.
