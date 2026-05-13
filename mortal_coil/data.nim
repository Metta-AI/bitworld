import soul

type
  PlayerKind* = enum
    PlayerHuman
    PlayerBot

  Vote* = enum
    VotePending
    VotePass
    VoteVeto

  Player* = object
    name*: string
    colorIndex*: int
    ready*: bool
    kind*: PlayerKind
    soul*: Soul
    cursor*: int
    magicTokens*: int
