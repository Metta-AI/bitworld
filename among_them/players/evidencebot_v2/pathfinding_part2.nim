proc inReportRange(bot: Bot, targetX, targetY: int): bool =
  ## Returns true when the target point is in report range.
  let
    ax = bot.playerWorldX() + CollisionW div 2
    ay = bot.playerWorldY() + CollisionH div 2
    bx = targetX + CollisionW div 2
    by = targetY + CollisionH div 2
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy <= bot.sim.config.reportRange * bot.sim.config.reportRange

proc inKillRange(bot: Bot, targetX, targetY: int): bool =
  ## Returns true when the target point is in imposter kill range.
  let
    ax = bot.playerWorldX() + CollisionW div 2
    ay = bot.playerWorldY() + CollisionH div 2
    bx = targetX + CollisionW div 2
    by = targetY + CollisionH div 2
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy <= bot.sim.config.killRange * bot.sim.config.killRange

