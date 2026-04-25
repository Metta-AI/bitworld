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
name of the key, followed by address:port and value:

```text
reward 127.0.0.1:54002 200
```

The packet format is ASCII compatible UTF-8 text. Lines end with `\n`. A sender
may use `\r\n`. A receiver should ignore empty lines.

## Line Format

```text
<name> <address>:<port> <value>
```

| Field | Type | Notes |
| --- | --- | --- |
| Name | `string` | Name of the value |
| Address | `string` | Player address |
| Port | `u16` | Player port |
| Value | `integer` | Value for this player |

`Address` and `Port` are written as one field separated by `:`. `Address` must
not contain spaces. `Port` and `Value` are written as base 10 integers.

The current required name is:

| Name | Meaning |
| --- | --- |
| `reward` | Reward used for training |

The server must send one `reward` line for each player in each tick packet.

## Multiple Players

A packet may contain reward data for multiple players. Each line identifies the
player that the value belongs to.

```text
reward 127.0.0.1:54002 200
reward 127.0.0.1:54003 -25
```

The same packet should not contain two lines with the same name and player. If
it does, the last line should replace earlier lines for that name and player.

## Future Values

Future versions may add more names. Useful examples include:

```text
reward 127.0.0.1:54002 200
advantage 127.0.0.1:54002 40
steps 127.0.0.1:54002 12
```

A receiver must read `reward` values. A receiver should ignore names it does not
understand.

## Message Rules

A server-to-client text message is one reward packet for one simulation tick.

The server should send packets in simulation tick order. If no players are
connected, the server may send an empty packet or skip the tick.

Client-to-server messages are not used by this protocol.

Binary websocket messages are invalid in this version.
