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
    power*: int

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

  ConflictStep* = enum
    ConflictGazing
    ConflictTitle
    ConflictDescription
    ConflictChoices
    ConflictResolution

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
    header*: string
    choice*: ChoiceCtx
    step*: SceneStep

  ConflictState* = object
    step*: ConflictStep
    round*: int
    schemes*: array[4, ChoiceScheme]
    sceneState*: SceneState
    sceneTimer*: int
    sceneTurnOrder*: seq[int]
    sceneTurnIndex*: int
    resolution*: string
