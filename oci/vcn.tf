# Single VCN (1 of the 2 free), public subnet for the LB, private subnet for the
# OKE worker node. All free-tier components: IGW, NAT GW, and route tables carry
# no hourly cost — only actual compute/LB/volume usage does.

resource "oci_core_vcn" "main" {
  compartment_id = var.tenancy_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "ai-notification-vcn"
  dns_label      = "ainotif"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-nat"
}

# Required for OKE worker nodes to register with the control plane — per
# Oracle's own docs this is mandatory, not optional: the node needs to reach
# OCI's own regional service endpoints (Object Storage, Container Engine,
# etc.), and that's a different path than "generic internet via NAT". This
# is what was actually missing when the node launched but timed out waiting
# to register.
data "oci_core_services" "all" {}

locals {
  osn_service = [
    for s in data.oci_core_services.all.services :
    s if length(regexall("Services In Oracle Services Network", s.name)) > 0
  ][0]
}

resource "oci_core_service_gateway" "sgw" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-sgw"

  services {
    service_id = local.osn_service.id
  }
}

# --- Public subnet: only the Load Balancer lives here ---

resource "oci_core_route_table" "public" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-public-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6" # TCP
    tcp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6" # TCP
    tcp_options {
      min = 80
      max = 80
    }
  }

  # Kubernetes API (6443) — the OKE control plane endpoint lives in this
  # subnet. Scoped to your laptop (kubectl) and to the private subnet
  # (worker nodes talking to the API server) — not open to the internet.
  ingress_security_rules {
    source   = var.my_ip_cidr
    protocol = "6" # TCP
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    source   = var.private_subnet_cidr
    protocol = "6" # TCP
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # Port 12250 — the other half of worker <-> control-plane communication
  # that OKE requires (6443 alone isn't sufficient). Missing this was the
  # second reason the node never registered.
  ingress_security_rules {
    source   = var.private_subnet_cidr
    protocol = "6" # TCP
    tcp_options {
      min = 12250
      max = 12250
    }
  }

  # OCI's own OKE cloud-controller-manager adds rules here directly
  # (outside Terraform) whenever a Service of type=LoadBalancer is
  # created/changed — NodePort ranges for the LB to reach, kube-proxy's
  # healthz port, etc. Without this, `terraform plan` sees that drift as
  # "rules to remove" and applying it would rip out exactly what the LB
  # needs to route traffic to the node. Same fix as ArgoCD's
  # ignoreDifferences for HPA-managed replica counts, just OCI's version.
  lifecycle {
    ignore_changes = [ingress_security_rules, egress_security_rules]
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.tenancy_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "ai-notification-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
}

# --- Private subnet: OKE worker node lives here, no public IP ---

resource "oci_core_route_table" "private" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat.id
  }

  route_rules {
    destination       = local.osn_service.cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.sgw.id
  }
}

resource "oci_core_security_list" "private" {
  compartment_id = var.tenancy_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ai-notification-private-sl"

  # All outbound allowed (image pulls, OpenAI/Gemini calls via NAT).
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Traffic from the public subnet (the LB) reaching node ports.
  ingress_security_rules {
    source   = var.public_subnet_cidr
    protocol = "6" # TCP
  }

  # Intra-VCN traffic (node<->node, kube-apiserver<->kubelet, etc).
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "all"
  }

  # Same reasoning as the public security list's lifecycle block above --
  # OCI's OKE cloud-controller-manager mutates this one directly too
  # (kube-proxy healthz, NodePort ranges) whenever a LoadBalancer Service
  # changes.
  lifecycle {
    ignore_changes = [ingress_security_rules, egress_security_rules]
  }
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.tenancy_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "ai-notification-private"
  dns_label                  = "private"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true
}

output "vcn_id" {
  value = oci_core_vcn.main.id
}

output "public_subnet_id" {
  value = oci_core_subnet.public.id
}

output "private_subnet_id" {
  value = oci_core_subnet.private.id
}
