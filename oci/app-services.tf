# The 13 app services were deployed directly here as Tier 1 (Phase 3),
# then handed off to ArgoCD once it existed (Phase 4) -- see
# platform-gitops/k8s/argocd/applicationsets/nest-services-prod.yaml and
# .../applications/{web,prediction-service}-prod.yaml. `terraform state rm`
# removed them from this state without touching the live resources; ArgoCD
# adopted them in place with zero pod disruption (confirmed: every pod kept
# its original creation timestamp through the handoff). Nothing left to
# declare here -- this file is intentionally empty of resources now.
