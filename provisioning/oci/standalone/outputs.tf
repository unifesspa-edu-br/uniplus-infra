output "k8s_host_ocid" {
  description = "OCID da instância k8s-host."
  value       = oci_core_instance.k8s_host.id
}

output "k8s_host_public_ip" {
  description = "IP público do k8s-host (não-Reserved no momento; pode mudar em recreate)."
  value       = oci_core_instance.k8s_host.public_ip
}

output "k8s_host_private_ip" {
  description = "IP privado do k8s-host (subnet pública)."
  value       = oci_core_instance.k8s_host.private_ip
}

output "data_host_ocid" {
  description = "OCID da instância data-host."
  value       = oci_core_instance.data_host.id
}

output "data_host_private_ip" {
  description = "IP privado do data-host (subnet privada; sem público)."
  value       = oci_core_instance.data_host.private_ip
}

output "data_volume_ocids" {
  description = "Mapa de OCIDs dos block volumes do data-host (postgres, kafka, minio, vault)."
  value       = { for k, v in oci_core_volume.data : k => v.id }
}

output "applied_profile" {
  description = "Perfil de capacidade aplicado (poc | hml)."
  value       = var.profile
}

output "applied_shapes" {
  description = "Shape config efetivo das 2 VMs."
  value = {
    k8s_host  = local.shapes.k8s_host
    data_host = local.shapes.data_host
  }
}
