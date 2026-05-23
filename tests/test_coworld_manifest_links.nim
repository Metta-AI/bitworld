import
  std/[json, os, sequtils, strutils]

const
  RootDir = currentSourcePath.parentDir.parentDir
  AmongThemManifestPath = RootDir / "among_them" / "coworld_manifest.json"
  PublicCoworldSchemaUrl =
    "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json"
  PrivateMettaGithubUrl = "github.com/Metta-AI/" & "metta"
  PrivateMettaRawUrl = "raw.githubusercontent.com/Metta-AI/" & "metta"

let
  manifestText = readFile(AmongThemManifestPath)
  manifest = parseJson(manifestText)

doAssert manifest["$schema"].getStr() == PublicCoworldSchemaUrl

let manifestPaths = toSeq(walkFiles(RootDir / "**" / "coworld_manifest.json"))
doAssert manifestPaths.len > 1
for path in manifestPaths:
  let text = readFile(path)
  doAssert PrivateMettaGithubUrl notin text
  doAssert PrivateMettaRawUrl notin text

echo "All tests passed"
