terraform {
    required_version = ">= 1.5.0"

    required_providers {
        oci = {
            source  = "oracle/oci"
            version = ">= 5.0.0"
        }
    }
}

provider "oci" {
    tenancy_ocid     = var.tenancy_ocid
    user_ocid        = var.user_ocid
    fingerprint      = var.fingerprint
    private_key_path = var.private_key_path
    region           = var.region
}

variable "tenancy_ocid" { type = string }
variable "user_ocid" { type = string }
variable "fingerprint" { type = string }
variable "private_key_path" { type = string }
variable "region" { type = string }

variable "compartment_ocid" {
    type        = string
    description = "OCID of the compartment to deploy into."
}

variable "display_name_prefix" {
    type    = string
    default = "opentofudemo"
}

variable "docker_image" {
    type        = string
    description = "Full path to Docker image in OCIR (e.g., <region-key>.ocir.io/<tenancy-namespace>/opentofudemo:latest)"
}

variable "ocir_username" {
    type        = string
    description = "OCIR username (format: <tenancy-namespace>/<username>)"
}

variable "ocir_password" {
    type        = string
    sensitive   = true
    description = "OCIR auth token"
}

# VCN for container instance
resource "oci_core_vcn" "vcn" {
    compartment_id = var.compartment_ocid
    cidr_block     = "10.0.0.0/16"
    display_name   = "${var.display_name_prefix}-vcn"
    dns_label      = "vcn"
}

resource "oci_core_internet_gateway" "igw" {
    compartment_id = var.compartment_ocid
    vcn_id         = oci_core_vcn.vcn.id
    display_name   = "${var.display_name_prefix}-igw"
    enabled        = true
}

resource "oci_core_route_table" "rt" {
    compartment_id = var.compartment_ocid
    vcn_id         = oci_core_vcn.vcn.id
    display_name   = "${var.display_name_prefix}-rt"

    route_rules {
        destination       = "0.0.0.0/0"
        destination_type  = "CIDR_BLOCK"
        network_entity_id = oci_core_internet_gateway.igw.id
    }
}

resource "oci_core_security_list" "sl" {
    compartment_id = var.compartment_ocid
    vcn_id         = oci_core_vcn.vcn.id
    display_name   = "${var.display_name_prefix}-sl"

    egress_security_rules {
        protocol    = "all"
        destination = "0.0.0.0/0"
    }

    # HTTP
    ingress_security_rules {
        protocol = "6" # TCP
        source   = "0.0.0.0/0"

        tcp_options {
            min = 80
            max = 80
        }
    }

    # HTTPS
    ingress_security_rules {
        protocol = "6" # TCP
        source   = "0.0.0.0/0"

        tcp_options {
            min = 443
            max = 443
        }
    }

    # Next.js dev/prod port
    ingress_security_rules {
        protocol = "6" # TCP
        source   = "0.0.0.0/0"

        tcp_options {
            min = 3000
            max = 3000
        }
    }
}

resource "oci_core_subnet" "subnet" {
    compartment_id             = var.compartment_ocid
    vcn_id                     = oci_core_vcn.vcn.id
    cidr_block                 = "10.0.1.0/24"
    display_name               = "${var.display_name_prefix}-subnet"
    dns_label                  = "subnet"
    route_table_id             = oci_core_route_table.rt.id
    security_list_ids          = [oci_core_security_list.sl.id]
    dhcp_options_id            = oci_core_vcn.vcn.default_dhcp_options_id
    prohibit_public_ip_on_vnic = false
}

# Container Instance
resource "oci_container_instances_container_instance" "app" {
    compartment_id              = var.compartment_ocid
    availability_domain         = data.oci_identity_availability_domains.ads.availability_domains[0].name
    display_name                = "${var.display_name_prefix}-container"
    shape                       = "CI.Standard.E4.Flex"
    
    shape_config {
        ocpus         = 1
        memory_in_gbs = 4
    }

    vnics {
        subnet_id              = oci_core_subnet.subnet.id
        display_name           = "${var.display_name_prefix}-vnic"
        is_public_ip_assigned  = true
        skip_source_dest_check = false
    }

    containers {
        display_name = "opentofudemo"
        image_url    = var.docker_image

        environment_variables = {
            NODE_ENV = "production"
            PORT     = "3000"
        }
    }

    image_pull_secrets {
        registry_endpoint = split("/", var.docker_image)[0]
        secret_type      = "BASIC"
        username         = var.ocir_username
        password         = var.ocir_password
    }

    container_restart_policy = "ALWAYS"
}

data "oci_identity_availability_domains" "ads" {
    compartment_id = var.tenancy_ocid
}

data "oci_core_vnic" "container_vnic" {
    vnic_id = oci_container_instances_container_instance.app.vnics[0].vnic_id
}

output "container_instance_id" {
    value = oci_container_instances_container_instance.app.id
}

output "container_public_ip" {
    value       = data.oci_core_vnic.container_vnic.public_ip_address
    description = "Public IP of the container instance"
}

output "app_url" {
    value       = "http://${data.oci_core_vnic.container_vnic.public_ip_address}:3000"
    description = "URL to access the Next.js application"
}
