import
  std/[json, os, strutils]

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
doAssert PrivateMettaGithubUrl notin manifestText
doAssert PrivateMettaRawUrl notin manifestText

echo "All tests passed"
