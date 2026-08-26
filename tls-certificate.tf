# ACM Certificate for the domain (skipped when skip_dns_setup is true)
resource "aws_acm_certificate" "cert" {
  count             = var.skip_dns_setup ? 0 : 1
  domain_name       = var.domain
  validation_method = "DNS"

  tags = {
    Name = local.tag_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Create Route53 zone for the domain (skipped when skip_dns_setup is true)
resource "aws_route53_zone" "zone" {
  count = var.skip_dns_setup ? 0 : 1
  name  = var.domain

  tags = {
    Name = local.tag_name
  }
}

# Create DNS records for certificate validation (skipped when skip_dns_setup is true)
resource "aws_route53_record" "cert_validation" {
  for_each = var.skip_dns_setup ? {} : {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.zone[0].zone_id
}

# Certificate validation (skipped when skip_dns_setup is true)
resource "aws_acm_certificate_validation" "cert" {
  count                   = var.skip_dns_setup ? 0 : 1
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Certificates for hostnames that only redirect to var.domain. The load balancer
# controller discovers these by matching the ingress hostnames.
resource "aws_acm_certificate" "redirect" {
  for_each = toset(var.redirect_domains)

  domain_name       = each.value
  validation_method = "DNS"

  tags = {
    Name = local.tag_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Validation records go in the parent zone, i.e. the domain minus its first label
data "aws_route53_zone" "redirect" {
  for_each = toset(var.redirect_domains)

  name         = join(".", slice(split(".", each.value), 1, length(split(".", each.value))))
  private_zone = false
}

resource "aws_route53_record" "redirect_cert_validation" {
  for_each = toset(var.redirect_domains)

  allow_overwrite = true
  name            = one(aws_acm_certificate.redirect[each.value].domain_validation_options).resource_record_name
  records         = [one(aws_acm_certificate.redirect[each.value].domain_validation_options).resource_record_value]
  ttl             = 60
  type            = one(aws_acm_certificate.redirect[each.value].domain_validation_options).resource_record_type
  zone_id         = data.aws_route53_zone.redirect[each.value].zone_id
}

resource "aws_acm_certificate_validation" "redirect" {
  for_each = toset(var.redirect_domains)

  certificate_arn         = aws_acm_certificate.redirect[each.value].arn
  validation_record_fqdns = [aws_route53_record.redirect_cert_validation[each.value].fqdn]
}

# Get the ALB details
data "aws_lb" "ingress" {
  tags = {
    "elbv2.k8s.aws/cluster"    = var.name
    "ingress.k8s.aws/stack"    = "langfuse/langfuse"
    "ingress.k8s.aws/resource" = "LoadBalancer"
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.langfuse
  ]
}

# Create Route53 record for the ALB (skipped when skip_dns_setup is true)
resource "aws_route53_record" "langfuse" {
  count   = var.skip_dns_setup ? 0 : 1
  zone_id = aws_route53_zone.zone[0].zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = data.aws_lb.ingress.dns_name
    zone_id                = data.aws_lb.ingress.zone_id
    evaluate_target_health = true
  }
}
