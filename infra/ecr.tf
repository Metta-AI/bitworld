resource "aws_ecr_repository" "crewrift" {
  name                 = "${var.project_name}/crewrift"
  image_tag_mutability = "MUTABLE"
  lifecycle { ignore_changes = [tags, tags_all] }
}
