resource "oci_core_vcn" "staging" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.42.0.0/16"]
  display_name   = "finance-control-staging-vcn"
  dns_label      = "financestg"
}

resource "oci_core_internet_gateway" "staging" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.staging.id
  display_name   = "finance-control-staging-internet-gateway"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.staging.id
  display_name   = "finance-control-staging-public-routes"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.staging.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.staging.id
  display_name   = "finance-control-staging-public-security"

  ingress_security_rules {
    protocol = "6"
    source   = var.ssh_allowed_cidr

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    protocol = "17"
    source   = "0.0.0.0/0"

    udp_options {
      min = 443
      max = 443
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.staging.id
  cidr_block                 = "10.42.1.0/24"
  display_name               = "finance-control-staging-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_instance" "staging" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.instance_display_name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "finance-control-staging-vnic"
    hostname_label   = "finance-control"
    subnet_id        = oci_core_subnet.public.id
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = 50
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      ssh_public_key = var.ssh_public_key
    }))
  }

  freeform_tags = {
    Application = "finance-control"
    Environment = "staging"
    CostPolicy  = "always-free-only"
  }

  preserve_boot_volume = false
}
