import soul
import choose

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

  GamePhase* = enum
    PhaseLobby
    PhaseWorld
    PhaseMagicalFacts
    PhaseSituation
    PhaseConflict
    PhasePower
    PhaseEnd

  ChatEntry* = object
    name*: string
    colorIndex*: uint8
    text*: string

  WorldStep* = enum
    WorldGazing
    WorldTitle
    WorldDescription

  SituationStep* = enum
    SituationGazing
    SituationTitle
    SituationDescription
    SituationChoices

  SceneStep* = enum
    SceneGazing
    SceneReading

  FactStep* = enum
    FactGazing
    FactReading
    FactSelected
    FactVoting
    FactVoteResult
    FactShowChat

  FactChoice* = object
    choice*: ChoiceCtx
    step*: FactStep
    votes*: seq[Vote]
    voteTimers*: seq[int]
    voteResultTimer*: int

  SceneState* = object
    choice*: ChoiceCtx
    step*: SceneStep
