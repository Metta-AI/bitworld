# ECR Repositories
#
# Naming convention: {owner}/{role}/{name}
#   owner = developer who maintains the image (treeform, monofuel, etc.)
#   role  = games, players, reporters, commissioners, graders, diagnosers, optimizers
#   name  = image name
#
# Public vs Private ECR:
#   - Public (aws_ecrpublic_repository): world-readable, no auth needed to pull.
#     Endpoint: public.ecr.aws/<alias>/<repo-name>
#     Use for: game images and bundled players that appear in coworld manifests,
#     since anyone running episodes locally or the hosted runner needs to pull them
#     without special credentials.
#     Push still requires auth (aws ecr-public get-login-password).
#
#   - Private (aws_ecr_repository): pull requires IAM auth in this account.
#     Endpoint: <account-id>.dkr.ecr.<region>.amazonaws.com/<repo-name>
#     Use for: user-submitted policies, internal tooling images, anything that
#     shouldn't be world-readable.

resource "aws_ecrpublic_repository" "crewrift_game" {
  repository_name = "treeform/games/crewrift"
}

resource "aws_ecrpublic_repository" "crewrift_notsus" {
  repository_name = "treeform/players/notsus"
}
