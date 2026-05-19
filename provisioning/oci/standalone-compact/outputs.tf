output "k8s_host_ocid" {
  description = "OCID da instância k8s-host."
  value       = oci_core_instance.k8s_host.id
}

output "k8s_host_public_ip" {
  description = "IP público do k8s-host (Reserved — sobrevive a recreate)."
  value       = oci_core_public_ip.k8s_host.ip_address
}

output "k8s_host_private_ip" {
  description = "IP privado do k8s-host."
  value       = oci_core_instance.k8s_host.private_ip
}

output "data_host_ocid" {
  description = "OCID da instância data-host."
  value       = oci_core_instance.data_host.id
}

output "data_host_public_ip" {
  description = "IP público efêmero do data-host (egress; SL bloqueia ingress da internet)."
  value       = oci_core_instance.data_host.public_ip
}

output "data_host_private_ip" {
  description = "IP privado do data-host."
  value       = oci_core_instance.data_host.private_ip
}

output "data_volume_ocid" {
  description = "OCID do block volume único de dados (~100 GB) no data-host."
  value       = oci_core_volume.data.id
}

output "vcn_ocid" {
  description = "OCID da VCN do compact."
  value       = oci_core_vcn.this.id
}

output "subnet_k8s_host_ocid" {
  description = "OCID da subnet pública do k8s-host."
  value       = oci_core_subnet.k8s_host.id
}

output "subnet_data_host_ocid" {
  description = "OCID da subnet pública do data-host (SL restritiva)."
  value       = oci_core_subnet.data_host.id
}

output "internet_gateway_ocid" {
  description = "OCID do Internet Gateway."
  value       = oci_core_internet_gateway.this.id
}

output "k8s_host_reserved_ip_ocid" {
  description = "OCID do Reserved Public IP do k8s-host."
  value       = oci_core_public_ip.k8s_host.id
}

output "dns_apex_fqdn" {
  description = "FQDN do apex do compact (record A → reserved IP)."
  value       = local.apex_domain
}

output "ssh_commands" {
  description = "Comandos SSH para acessar os 2 hosts (k8s-host direto, data-host via jump)."
  value = {
    k8s_host  = "ssh ubuntu@${oci_core_public_ip.k8s_host.ip_address}"
    data_host = "ssh -J ubuntu@${oci_core_public_ip.k8s_host.ip_address} ubuntu@${oci_core_instance.data_host.private_ip}"
  }
}

output "applied_shapes" {
  description = "Shape config efetivo das 2 VMs."
  value       = local.shapes
}
