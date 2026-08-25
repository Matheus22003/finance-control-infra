terraform {
  required_version = "1.13.3"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.25.0"
    }
  }
}

provider "oci" {
  region = var.region
}
