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
    # Configure via env vars (recommended):
    # TF_VAR_tenancy_ocid, TF_VAR_user_ocid, TF_VAR_fingerprint, TF_VAR_private_key_path, TF_VAR_region
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

variable "vcn_cidr" {
    type    = string
    default = "10.0.0.0/16"
}

variable "subnet_cidr" {
    type    = string
    default = "10.0.1.0/24"
}

variable "display_name_prefix" {
    type    = string
    default = "demo"
}

variable "ssh_public_key" {
    type        = string
    description = "SSH public key contents for instance access."
}

variable "instance_shape" {
    type    = string
    default = "VM.Standard.E4.Flex"
}

variable "instance_ocpus" {
    type    = number
    default = 1
}

variable "instance_memory_gbs" {
    type    = number
    default = 8
}

data "oci_identity_availability_domains" "ads" {
    compartment_id = var.tenancy_ocid
}

data "oci_core_images" "oracle_linux" {
    compartment_id           = var.compartment_ocid
    operating_system         = "Oracle Linux"
    operating_system_version = "8"
    shape                    = var.instance_shape

    sort_by    = "TIMECREATED"
    sort_order = "DESC"
}

resource "oci_core_vcn" "vcn" {
    compartment_id = var.compartment_ocid
    cidr_block     = var.vcn_cidr
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

    ingress_security_rules {
        protocol = "6" # TCP
        source   = "0.0.0.0/0"

        tcp_options {
            min = 22
            max = 22
        }
    }

    # Optional: allow ICMP for troubleshooting
    ingress_security_rules {
        protocol = "1" # ICMP
        source   = "0.0.0.0/0"

        icmp_options {
            type = 3
            code = 4
        }
    }
}

resource "oci_core_subnet" "subnet" {
    compartment_id      = var.compartment_ocid
    vcn_id              = oci_core_vcn.vcn.id
    cidr_block          = var.subnet_cidr
    display_name        = "${var.display_name_prefix}-subnet"
    dns_label           = "subnet"
    route_table_id      = oci_core_route_table.rt.id
    security_list_ids   = [oci_core_security_list.sl.id]
    dhcp_options_id     = oci_core_vcn.vcn.default_dhcp_options_id
    prohibit_public_ip_on_vnic = false
}

resource "oci_core_instance" "vm" {
    compartment_id      = var.compartment_ocid
    availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
    display_name        = "${var.display_name_prefix}-vm"
    shape               = var.instance_shape

    shape_config {
        ocpus         = var.instance_ocpus
        memory_in_gbs = var.instance_memory_gbs
    }

    create_vnic_details {
        subnet_id        = oci_core_subnet.subnet.id
        assign_public_ip = true
        display_name     = "${var.display_name_prefix}-vnic"
        hostname_label   = "vm"
    }

    metadata = {
        ssh_authorized_keys = var.ssh_public_key
    }

    source_details {
        source_type = "image"
        source_id   = data.oci_core_images.oracle_linux.images[0].id
    }
}

output "instance_public_ip" {
    value = oci_core_instance.vm.public_ip
}

output "instance_id" {
    value = oci_core_instance.vm.id
}

output "vcn_id" {
    value = oci_core_vcn.vcn.id
}

output "subnet_id" {
    value = oci_core_subnet.subnet.id
}