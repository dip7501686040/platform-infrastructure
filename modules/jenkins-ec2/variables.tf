variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (22) and the Jenkins UI (8080). No safe default for AWS — set consciously."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "github_push_username" {
  type    = string
  default = ""
}

variable "github_push_token" {
  description = "GitHub PAT Jenkins uses to push tag-bump commits — seeded into the instance's Jenkins credential store at boot via init.groovy.d. Empty string skips seeding the credential."
  type        = string
  sensitive   = true
  default     = ""
}

variable "service_names" {
  description = "One pre-configured, one-click build-<service> job is seeded per name at boot, in addition to the generic parameterized build-service job."
  type        = list(string)
  default     = []
}

variable "git_repo_url" {
  description = "The platform-gitops repo — holds this Jenkinsfile plus the k8s/terraform this pipeline reads and pushes tag-bump commits to. Public, so the seeded job SCM checkout clones anonymously; only the tag-bump push needs the github-push credential."
  type        = string
  default     = "https://github.com/dip7501686040/platform-gitops.git"
}

variable "git_branch" {
  type    = string
  default = "main"
}
