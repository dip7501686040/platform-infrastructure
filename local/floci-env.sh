# Source this once per terminal session to point aws/terraform/kubectl at
# Floci without repeating exports on every command:
#
#   source local/floci-env.sh                      # if already cd'd into platform-gitops
#   source ../platform-gitops/local/floci-env.sh    # from ai-notification-system
#
# Scoped to this repo only — does not touch ~/.aws. aws-config/aws-credentials
# in this same directory are committed as-is (not gitignored): Floci's values
# are the same fixed dummy credentials for everyone, not a real secret.

_FLOCI_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

export AWS_CONFIG_FILE="${_FLOCI_ENV_DIR}/aws-config"
export AWS_SHARED_CREDENTIALS_FILE="${_FLOCI_ENV_DIR}/aws-credentials"
export AWS_PROFILE=floci

unset _FLOCI_ENV_DIR
