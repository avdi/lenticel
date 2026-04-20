output "vps_ip" {
  description = "Public IP of the lenticel VPS"
  value       = vultr_instance.lenticel.main_ip
}

output "ssh_connect" {
  description = "SSH connection string"
  value       = "ssh root@${vultr_instance.lenticel.main_ip}"
}

output "nameservers" {
  description = "Bunny DNS nameservers — set these at your registrar for your domain"
  value = [
    bunnynet_dns_zone.lenticel.nameserver1,
    bunnynet_dns_zone.lenticel.nameserver2,
  ]
}

output "test_url" {
  description = "URL to test after DNS propagates"
  value       = "https://anything.${var.domain}"
}
