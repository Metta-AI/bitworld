const
  PlayerScreenX = ScreenWidth div 2
  PlayerScreenY = ScreenHeight div 2
  PlayerWorldOffX = SpriteDrawOffX + PlayerScreenX - SpriteSize div 2
  PlayerWorldOffY = SpriteDrawOffY + PlayerScreenY - SpriteSize div 2
  FullFrameFitMaxErrors = 420
  LocalFrameFitMaxErrors = 320
  FrameFitMinCompared = 12000
  LocalFrameSearchRadius = 8
  PatchSize = 8
  PatchGridW = ScreenWidth div PatchSize
  PatchGridH = ScreenHeight div PatchSize
  PatchHashBase = 16777619'u64
  PatchHashSeed = 14695981039346656037'u64
  PatchMaxMatches = 4096
  PatchTopCandidates = 16
  PatchMinVotes = 3
  PlayerIgnoreRadius = 9
  InterstitialBlackPercent = 30
  HomeSearchRadius = 20
  PlayerDefaultPort = DefaultPort
  ViewerWindowWidth = 1820
  ViewerWindowHeight = 1060
  ViewerMargin = 16.0'f
  ViewerFrameScale = 4.0'f
  ViewerMapScale = 1.25'f
  ViewerBackground = rgbx(17, 20, 28, 255)
  ViewerPanel = rgbx(33, 38, 50, 255)
  ViewerPanelAlt = rgbx(25, 30, 41, 255)
  ViewerText = rgbx(226, 231, 240, 255)
  ViewerMutedText = rgbx(146, 155, 172, 255)
  ViewerViewport = rgbx(142, 193, 255, 180)
  ViewerButton = rgbx(255, 196, 88, 255)
  ViewerPlayer = rgbx(120, 255, 170, 255)
  ViewerCrew = rgbx(82, 168, 255, 255)
  ViewerImp = rgbx(255, 84, 96, 255)
  ViewerTask = rgbx(255, 132, 146, 255)
  ViewerTaskGuess = rgbx(255, 220, 92, 255)
  ViewerRadarLine = rgbx(255, 220, 92, 210)
  ViewerPath = rgbx(119, 218, 255, 230)
  ViewerWalk = rgbx(46, 61, 75, 255)
  ViewerWall = rgbx(86, 50, 56, 255)
  ViewerUnknown = rgbx(22, 26, 36, 255)
  RadarTaskColor = 8'u8
  RadarPeripheryMargin = 1
  RadarMatchTolerance = 2
  TaskIconSearchRadius = 2
  TaskIconExpectedSearchRadius = 3
  TaskIconMaxMisses = 4
  TaskIconMaybeMisses = 12
  TaskIconInspectSize = 16
  TaskClearScreenMargin = 8
  TaskIconMissThreshold = 24
  PathLookahead = 18
  TaskInnerMargin = 6
  TaskPreciseApproachRadius = 12
  CoastLookaheadTicks = 8
  CoastArrivalPadding = 1
  SteerDeadband = 2
  BrakeDeadband = 1
  StuckFrameThreshold = 8
  JiggleDuration = 16
  TaskHoldPadding = 8
  CrewmateSearchRadius = 1
  CrewmateMaxMisses = 8
  CrewmateMinStablePixels = 8
  CrewmateMinBodyPixels = 8
  KillIconX = 1
  KillIconY = ScreenHeight - SpriteSize - 1
  KillIconMaxMisses = 5
  GhostIconMaxMisses = 3
  GhostIconFrameThreshold = 2
  KillApproachRadius = 3
  # A non-self crewmate within this many world pixels of a body is "next to"
  # it for accusation purposes. Wide enough to forgive a step or two of
  # motion, tight enough not to implicate anyone passing through the room.
  WitnessNearBodyRadius = KillRange * 2

  # Imposter follow-and-fake-task tuning.
  # ImposterFollowSwapMinTicks: minimum ticks we'll stick with one followee
  #   before we're allowed to swap when 2+ crewmates are visible. Prevents
  #   per-frame thrashing between targets. ~5-10 seconds of game time.
  # ImposterFollowApproachRadius: how close to navigate toward our followee.
  #   Tight enough to be in kill range if lone, loose enough not to bump.
  # ImposterFakeTaskNearRadius: world-px distance from a task center inside
  #   which the imposter is "passing by" and may roll to fake-do the task.
  # ImposterFakeTaskMinTicks/MaxTicks: duration of one fake-task action.
  # ImposterFakeTaskCooldownTicks: minimum gap between fake tasks.
  # ImposterFakeTaskChance: probability per eligible frame to start a fake
  #   task (rolled out of ImposterFakeTaskChanceDenom).
  ImposterFollowSwapMinTicks = 240
  ImposterFollowApproachRadius = 6
  ImposterFakeTaskNearRadius = 80
  ImposterFakeTaskMinTicks = 90
  ImposterFakeTaskMaxTicks = 180
  ImposterFakeTaskCooldownTicks = 240
  ImposterFakeTaskChance = 1
  ImposterFakeTaskChanceDenom = 12

  # Self-report tuning. After a kill we want the imposter to *report the
  # body it just made* instead of fleeing — the meeting opens immediately,
  # our queued random-innocent accusation flushes first, and we look like
  # the helpful crewmate who "found" the body. Classic imposter play.
  #
  # ImposterSelfReportRecentTicks: how many ticks after pressing kill-A we
  #   still treat the new body as "ours" for self-report purposes. The sim
  #   typically needs 1-2 ticks to draw the body sprite, so this just has
  #   to be wide enough to bridge that gap without misclassifying an
  #   unrelated body discovered seconds later.
  # ImposterSelfReportRadius: world-px tolerance between the victim's last
  #   position and the body sprite's drawn position. Slightly looser than
  #   the killer's own collision range to absorb sprite-draw offsets.
  ImposterSelfReportRecentTicks = 30
  ImposterSelfReportRadius = KillRange + 8

  BodySearchRadius = 1
  BodyMaxMisses = 9
  BodyMinStablePixels = 6
  BodyMinTintPixels = 6
  GhostSearchRadius = 1
  GhostMaxMisses = 9
  GhostMinStablePixels = 6
  GhostMinTintPixels = 6
  PlayerColorCount = PlayerColors.len
  PlayerColorNames = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]
  VoteCellW = 16
  VoteCellH = 17
  VoteStartY = 2
  VoteSkipW = 28
  VoteUnknown = -1
  VoteSkip = -2
  VoteBlackMarker = 12'u8
  VoteListenTicks = 100
  VoteChatTextX = 21
  VoteChatChars = 15
  FrameDropThreshold = 32
  MaxFrameDrain = 128

when not defined(evidencebotLibrary):
  type ViewerApp = ref object
    window: Window
    silky: Silky
