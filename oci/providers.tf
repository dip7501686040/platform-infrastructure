terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
  }
}

provider "oci" {
  region = var.region
}

# Reuses the kubeconfig `oci ce cluster create-kubeconfig` already wrote —
# same exec-based auth (fetches a short-lived token via ~/.oci) kubectl
# uses, so Terraform authenticates to the cluster exactly the same way.
provider "kubernetes" {
  config_path = pathexpand("~/.kube/config-oke-ainotif")
}

provider "helm" {
  kubernetes {
    config_path = pathexpand("~/.kube/config-oke-ainotif")
  }
}
