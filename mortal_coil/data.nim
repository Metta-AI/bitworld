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
    individuality*: int
    cooperativity*: int
    exploitativity*: int
    vicariousness*: int

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
    ConflictOutcome
    ConflictRecount
    ConflictResolution

  PlayerRoundResult* = object
    playerIndex*: int
    powerBefore*: int
    risk*: int
    bearer*: RiskTarget
    rewarded*: RiskTarget
    burdenTaken*: int      # player.burden from own choice
    partyBurden*: int      # burden distributed to party
    choiceResult*: int     # -1, 0, +1 from LLM
    rewardEarned*: int     # player's own reward
    partyReward*: int      # reward distributed to party

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
    outcome*: string
    roundResults*: seq[PlayerRoundResult]
    recountPlayer*: int
    recountLine*: int
    resolution*: string

proc chatLogStrings*(chatLog: seq[ChatEntry]): seq[string] =
  for entry in chatLog:
    result.add(entry.name & ": " & entry.text)
