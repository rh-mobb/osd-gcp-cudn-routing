output "wif_config_id" {
  value       = module.wif_config.wif_config_id
  description = "OCM WIF config ID"
}

output "wif_display_name" {
  value       = module.wif_config.display_name
  description = "WIF config display name (used by example data sources)"
}
