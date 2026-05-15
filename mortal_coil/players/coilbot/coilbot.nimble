version     = "0.1.0"
author      = "Andre von Houck"
description = "LLM-powered clientside bot for Mortal Coil."
license     = "MIT"

srcDir = "."

bin = @["coilbot"]

switch("path", "../../../common")
switch("path", "../../")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "pixie"
requires "whisky >= 0.1.3"
