import std/os
import bitworld/clients

proc rewardClientPath*(): string =
  ## Returns the reward client HTML path.
  clientsDir() / RewardClientHtml

proc readRewardClient*(): string {.raises: [IOError].} =
  ## Reads the reward client HTML.
  readFile(rewardClientPath())
