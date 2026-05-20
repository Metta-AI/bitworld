## Terraform wrapper for bitworld infrastructure.
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
  Region = "us-east-1"
  StateBucket = "bitworld-terraform-state-sandbox-andre"
  LockTable = "bitworld-terraform-lock"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir

proc usage() =
  echo """Usage: infra [COMMAND]

Terraform wrapper for bitworld infrastructure.

Commands:
  --bootstrap    Initialize state bucket + lock table (run once)
  --init         Run terraform init with backend config
  --validate     Check terraform syntax (no AWS creds needed)
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

proc ensureAwsCli() =
  let (output, code) = execCmdEx("aws --version")
  if code != 0:
    echo "Error: aws CLI not found on PATH."
    echo "Install from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    quit(1)
  echo "aws: ", output.strip().splitLines()[0]

proc awsExec(cmd: string): tuple[output: string, exitCode: int] =
  echo "  $ aws ", cmd
  result = execCmdEx("aws " & cmd)

proc bucketExists(): bool =
  let (_, code) = awsExec(
    "s3api head-bucket --bucket " & StateBucket & " --region " & Region
  )
  result = code == 0

proc tableExists(): bool =
  let (_, code) = awsExec(
    "dynamodb describe-table --table-name " & LockTable & " --region " & Region
  )
  result = code == 0

proc bootstrap() =
  echo "Bootstrapping Terraform state backend via AWS CLI..."
  echo "  bucket: ", StateBucket
  echo "  table:  ", LockTable
  echo "  region: ", Region
  echo ""
  ensureAwsCli()
  echo ""

  if bucketExists():
    echo "  S3 bucket already exists, skipping."
  else:
    echo "  Creating S3 bucket..."
    let (output, code) = awsExec(
      "s3api create-bucket --bucket " & StateBucket &
      " --region " & Region
    )
    if code != 0:
      echo "Error creating bucket: ", output
      quit(1)
    echo "  Enabling versioning..."
    discard awsExec(
      "s3api put-bucket-versioning --bucket " & StateBucket &
      " --versioning-configuration Status=Enabled"
    )
    echo "  Enabling encryption..."
    discard awsExec(
      "s3api put-bucket-encryption --bucket " & StateBucket &
      " --server-side-encryption-configuration " &
      "'{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'"
    )
    echo "  Blocking public access..."
    discard awsExec(
      "s3api put-public-access-block --bucket " & StateBucket &
      " --public-access-block-configuration " &
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    )
    echo "  S3 bucket created."

  echo ""

  if tableExists():
    echo "  DynamoDB table already exists, skipping."
  else:
    echo "  Creating DynamoDB lock table..."
    let (output, code) = awsExec(
      "dynamodb create-table --table-name " & LockTable &
      " --attribute-definitions AttributeName=LockID,AttributeType=S" &
      " --key-schema AttributeName=LockID,KeyType=HASH" &
      " --billing-mode PAY_PER_REQUEST" &
      " --region " & Region
    )
    if code != 0:
      echo "Error creating table: ", output
      quit(1)
    echo "  DynamoDB table created."

  echo ""
  echo "Bootstrap complete."
  echo "Next: nim r tools/infra.nim --init"

proc validate() =
  let dir = repoRoot() / InfraDir
  echo "Validating Terraform configuration..."
  echo ""
  ensureTerraform()
  execInDir("terraform init -backend=false", dir)
  echo ""
  execInDir("terraform validate", dir)
  echo ""
  echo "Validation passed."

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
  execInDir("terraform apply -auto-approve", dir)

proc destroy() =
  let dir = repoRoot() / InfraDir
  echo "WARNING: This will destroy all bitworld infrastructure."
  echo "Terraform will prompt for confirmation."
  echo ""
  ensureTerraform()
  execInDir("terraform destroy", dir)

proc output() =
  let dir = repoRoot() / InfraDir
  ensureTerraform()
  execInDir("terraform output", dir)

proc main() =
  putEnv("AWS_PROFILE", "sandbox-andre")
  var command = ""

  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "bootstrap": command = "bootstrap"
      of "validate": command = "validate"
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
  of "validate": validate()
  of "init": init()
  of "plan": plan()
  of "apply": apply()
  of "destroy": destroy()
  of "output": output()
  else: usage()

main()
