## Terraform wrapper for bitworld2 infrastructure.
##
## Manages AWS infrastructure (VPC, subnets, security groups, DNS Firewall)
## for running tournament bot containers on ECS Fargate with controlled egress.
##
## Prerequisites:
##   - terraform >= 1.5 (https://developer.hashicorp.com/terraform/install)
##   - AWS credentials configured (aws configure, or env vars)
##
## Usage:
##   nim r tools/infra.nim --bootstrap   # create state bucket (run once)
##   nim r tools/infra.nim --init        # terraform init
##   nim r tools/infra.nim --plan        # preview changes
##   nim r tools/infra.nim --apply       # apply changes
##   nim r tools/infra.nim --destroy     # tear down (prompts for confirmation)

import std/[os, osproc, parseopt, strutils]

const
  InfraDir = "infra"
  BootstrapDir = "infra" / "bootstrap"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir

proc usage() =
  echo """Usage: infra [COMMAND]

Terraform wrapper for bitworld2 infrastructure.

Commands:
  --bootstrap    Initialize state bucket + lock table (run once)
  --init         Run terraform init with backend config
  --plan         Run terraform plan (preview changes)
  --apply        Run terraform apply (create/update resources)
  --destroy      Run terraform destroy (tears everything down)
  --output       Show terraform outputs
  --help         Show this help"""
  quit(0)

proc ensureTerraform() =
  let (output, code) = execCmdEx("terraform version")
  if code != 0:
    echo "Error: terraform not found on PATH."
    echo "Install from: https://developer.hashicorp.com/terraform/install"
    quit(1)
  let firstLine = output.strip().splitLines()[0]
  echo "terraform: ", firstLine

proc execInDir(cmd: string, workDir: string) =
  echo "  $ ", cmd
  echo "  dir: ", workDir
  echo ""
  let code = execCmd("cd " & quoteShell(workDir) & " && " & cmd)
  if code != 0:
    echo ""
    echo "Error: command failed with exit code ", code
    quit(1)

proc bootstrap() =
  let dir = repoRoot() / BootstrapDir
  if not dirExists(dir):
    echo "Error: ", dir, " not found."
    quit(1)
  echo "Bootstrapping Terraform state backend..."
  echo "  This creates an S3 bucket and DynamoDB table for state locking."
  echo ""
  ensureTerraform()
  execInDir("terraform init", dir)
  echo ""
  execInDir("terraform apply", dir)
  echo ""
  echo "Bootstrap complete."
  echo "Next: nim r tools/infra.nim --init"

proc init() =
  let dir = repoRoot() / InfraDir
  echo "Initializing Terraform..."
  echo ""
  ensureTerraform()
  execInDir("terraform init", dir)
  echo ""
  echo "Init complete."
  echo "Next: nim r tools/infra.nim --plan"

proc plan() =
  let dir = repoRoot() / InfraDir
  echo "Planning infrastructure changes..."
  echo ""
  ensureTerraform()
  execInDir("terraform plan", dir)

proc apply() =
  let dir = repoRoot() / InfraDir
  echo "Applying infrastructure..."
  echo ""
  ensureTerraform()
  execInDir("terraform apply", dir)

proc destroy() =
  let dir = repoRoot() / InfraDir
  echo "WARNING: This will destroy all bitworld2 infrastructure."
  echo "Terraform will prompt for confirmation."
  echo ""
  ensureTerraform()
  execInDir("terraform destroy", dir)

proc output() =
  let dir = repoRoot() / InfraDir
  ensureTerraform()
  execInDir("terraform output", dir)

proc main() =
  var command = ""

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "bootstrap": command = "bootstrap"
      of "init": command = "init"
      of "plan": command = "plan"
      of "apply": command = "apply"
      of "destroy": command = "destroy"
      of "output": command = "output"
      of "help": usage()
      else:
        echo "Unknown option: --", key
        usage()
    of cmdShortOption:
      case key
      of "h": usage()
      else:
        echo "Unknown option: -", key
        usage()
    of cmdArgument:
      echo "Unexpected argument: ", key
      usage()
    of cmdEnd:
      discard

  if command.len == 0:
    usage()

  echo "infra"
  echo "  command: ", command
  echo ""

  case command
  of "bootstrap": bootstrap()
  of "init": init()
  of "plan": plan()
  of "apply": apply()
  of "destroy": destroy()
  of "output": output()
  else: usage()

main()
