# OKE Basic cluster (free control plane) + a single Ampere A1 Flex worker
# node using the full Always Free allocation (2 OCPU / 12GB). The API
# endpoint sits in the public subnet (so kubectl can reach it directly);
# the worker node sits in the private subnet (no public IP at all).

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_containerengine_cluster_option" "oke" {
  cluster_option_id = "all"
}

locals {
  # Pick the newest Kubernetes version OKE currently offers.
  latest_k8s_version = element(
    reverse(sort(data.oci_containerengine_cluster_option.oke.kubernetes_versions)),
    0
  )
}

resource "oci_containerengine_cluster" "main" {
  compartment_id     = var.tenancy_ocid
  name               = "ai-notification-oke"
  vcn_id             = oci_core_vcn.main.id
  kubernetes_version = local.latest_k8s_version
  type               = "BASIC_CLUSTER"

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY" # simpler than VCN-native — no extra pod subnet needed for 1 node
  }

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = oci_core_subnet.public.id
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.public.id]

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }
}

# Ask OCI which node images are actually compatible with THIS cluster's
# Kubernetes version, instead of hardcoding a region/version-specific OCID.
data "oci_containerengine_node_pool_option" "oke" {
  compartment_id      = var.tenancy_ocid
  node_pool_option_id = oci_containerengine_cluster.main.id
}

locals {
  # Filter to the Arm (aarch64) OKE platform image — required for
  # VM.Standard.A1.Flex, which is the Ampere/Arm shape the Always Free
  # allowance applies to.
  a1_image_id = [
    for s in data.oci_containerengine_node_pool_option.oke.sources :
    s.image_id if length(regexall("aarch64", lower(s.source_name))) > 0
  ][0]
}

resource "oci_containerengine_node_pool" "main" {
  compartment_id     = var.tenancy_ocid
  cluster_id         = oci_containerengine_cluster.main.id
  name               = "ai-notification-pool"
  kubernetes_version = local.latest_k8s_version
  node_shape         = "VM.Standard.A1.Flex"

  node_shape_config {
    ocpus         = 2 # the full Always Free A1 allowance
    memory_in_gbs = 12
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.a1_image_id
    boot_volume_size_in_gbs = 50
  }

  node_config_details {
    size = 1

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.private.id
    }

    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }
  }

  initial_node_labels {
    key   = "role"
    value = "app-and-backing"
  }
}

output "cluster_id" {
  value = oci_containerengine_cluster.main.id
}

output "node_pool_id" {
  value = oci_containerengine_node_pool.main.id
}

output "kubernetes_version" {
  value = local.latest_k8s_version
}
