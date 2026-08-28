#!/usr/bin/env bash
# Wrapper around `terraform` that always forces -parallelism=1 and always
# includes both var-files -- the two things every raw `terraform plan`/
# `apply` invocation this session had to remember by hand (and, twice,
# forgot: once dropping secrets.local.tfvars entirely, once running with
# Terraform's default parallelism=10).
#
# WHY -parallelism=1, always, not just "usually": Terraform's default lets
# up to 10 independent graph nodes execute concurrently. Every real
# incident behind scripts/cpu-priority.sh and scripts/cpu-watchdog.sh
# started from more than one cluster's provisioner running at once --
# confirmed live, that's not a caps-tuning problem, it's Terraform itself
# genuinely doing two clusters' worth of kubectl/helm work in parallel, each
# side fighting the other's CPU allocation. cpu-priority.sh's per-call
# "boost the active one" logic only means anything if exactly one such call
# is ever in flight -- parallelism=1 is what actually guarantees that, not
# just makes it more likely. Confirmed serially slower but correct is
# strictly preferred here: "delay is acceptable" is an explicit requirement,
# uncontrolled concurrent CPU contention is not.
#
# Usage: scripts/tf.sh plan   -target=... [-out=...]
#        scripts/tf.sh apply  <plan-file>
#        scripts/tf.sh apply  -target=...          (unsaved, prompts unless -auto-approve)
#        scripts/tf.sh <any other subcommand, e.g. validate/state/show> ...
#
# Same as running `terraform <subcommand> ...` by hand, except:
#   - AWS_PROFILE=floci (etc.) is sourced automatically (local/floci-env.sh)
#   - plan/apply/destroy/refresh get -parallelism=1 injected automatically
#   - plan/apply/destroy/refresh get both var-files injected automatically,
#     UNLESS the command is `apply <a-single-.tfplan-file-argument>` -- a
#     saved plan already has the vars baked in, passing -var-file again is
#     harmless but pointless, and `apply` doesn't accept -parallelism
#     alongside a saved plan file either (the plan already fixed that too)

set -euo pipefail

_tf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_tf_root="$(cd "$_tf_dir/.." && pwd)"
cd "$_tf_root"

source "$_tf_root/local/floci-env.sh"

_tf_sub="${1:-}"
_tf_varfiles=(-var-file=envs/local.tfvars -var-file=secrets.local.tfvars)

case "$_tf_sub" in
  plan|refresh)
    shift
    exec terraform "$_tf_sub" -parallelism=1 "${_tf_varfiles[@]}" "$@"
    ;;
  apply|destroy)
    shift
    # `apply <file.tfplan>` (a single positional arg, no leading -) --
    # saved plan, no var-files/-parallelism to add (see header comment).
    if [ "$_tf_sub" = "apply" ] && [ "$#" -eq 1 ] && [[ "$1" != -* ]] && [[ "$1" == *.tfplan ]]; then
      exec terraform apply "$1"
    fi
    exec terraform "$_tf_sub" -parallelism=1 "${_tf_varfiles[@]}" "$@"
    ;;
  *)
    exec terraform "$@"
    ;;
esac
