import std/os
import bitworld/clients

proc globalClientPath*(): string =
  ## Returns the global client HTML path.
  clientsDir() / GlobalClientHtml

proc readGlobalClient*(): string {.raises: [IOError].} =
  ## Reads the global client HTML.
  readFile(globalClientPath())
