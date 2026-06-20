# Private Google Access via the RESTRICTED VIP (spec §9.3) for the validator's OWN
# VPC. Mirrors host-dev/dns-restricted.tf for this standalone VPC. This is the
# companion to the 443->restricted-VIP egress allow in firewall.tf: that allow is
# INERT without this DNS->VIP mapping (without it, *.googleapis.com resolves to
# public Google IPs that the egress deny-floor blocks). No Cloud NAT, no external
# IPs on the API path — the validator reaches Secret Manager (token), KMS,
# Monitoring/Logging only through the VPC-SC-compatible restricted VIP. Restricted
# (not private) VIP is the seam the regulated turn-up later wraps in a VPC-SC
# perimeter — config, not a re-plumb.
#
# (Plan deviation: the Stage-4 file list named network.tf but not its DNS
# companion. The restricted-VIP firewall allow in Step 6 cannot function without
# this zone + route, so it is authored here. Documented for the checklist walk.)
resource "google_dns_managed_zone" "googleapis" {
  project     = module.validator.project_id
  name        = "csyn-ldg-validator-googleapis"
  dns_name    = "googleapis.com."
  description = "Private zone routing *.googleapis.com to the restricted VIP (PGA, no NAT)."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
  depends_on = [time_sleep.apis]
}

# restricted.googleapis.com -> the four restricted-VIP anycast addresses.
resource "google_dns_record_set" "restricted_a" {
  project      = module.validator.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "restricted.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

# Everything under googleapis.com resolves to the restricted endpoint.
resource "google_dns_record_set" "wildcard_cname" {
  project      = module.validator.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}

# Artifact Registry's docker endpoint (us-south1-docker.pkg.dev — see validator.tf
# image_ref) is on pkg.dev, NOT *.googleapis.com, so it needs its OWN private zone
# to the restricted VIP. Without it pkg.dev resolves PUBLIC and the egress deny-floor
# drops the image pull ("context deadline exceeded" at boot — CONSVAL1-A5). Mirrors
# host-dev's live csyn-ldg-dev-pkg-dev zone (apex A -> VIP, wildcard CNAME -> apex);
# resolves to the SAME VIP /30, so the existing restricted_vip route already covers it.
# gcr.io is intentionally NOT added — the validator pulls only from pkg.dev (add a
# gcr.io zone here if a gcr.io-hosted image is ever introduced).
resource "google_dns_managed_zone" "pkg_dev" {
  project     = module.validator.project_id
  name        = "csyn-ldg-validator-pkg-dev"
  dns_name    = "pkg.dev."
  description = "Private zone routing *.pkg.dev to the restricted VIP (Artifact Registry pulls, PGA, no NAT)."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
  depends_on = [time_sleep.apis]
}

resource "google_dns_record_set" "pkg_dev_a" {
  project      = module.validator.project_id
  managed_zone = google_dns_managed_zone.pkg_dev.name
  name         = "pkg.dev."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

resource "google_dns_record_set" "pkg_dev_wildcard" {
  project      = module.validator.project_id
  managed_zone = google_dns_managed_zone.pkg_dev.name
  name         = "*.pkg.dev."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["pkg.dev."]
}

# Static route: restricted VIP /30 -> default internet gateway. With PGA on the
# subnet this keeps API egress on-Google without any external connectivity.
# Covers BOTH googleapis.com and pkg.dev (both resolve to this same VIP /30).
resource "google_compute_route" "restricted_vip" {
  project          = module.validator.project_id
  name             = "csyn-ldg-validator-restricted-vip"
  network          = google_compute_network.vpc.name
  dest_range       = "199.36.153.4/30"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}
