data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_cloudfront_public_key" "generated_key" {
  encoded_key = jsondecode(module.cf_key.outputs).publicKey
}

resource "aws_cloudfront_public_key" "kms" {
  encoded_key = "-----BEGIN PUBLIC KEY-----\n${join("\n", regexall(".{1,64}", jsondecode(data.local_file.key.content).PublicKey))}\n-----END PUBLIC KEY-----\n"
}

resource "aws_cloudfront_key_group" "cf_keygroup" {
  items = [
		aws_cloudfront_public_key.generated_key.id,
		aws_cloudfront_public_key.kms.id,
	]
  name  = "${random_id.id.hex}-group"
	lifecycle {
		replace_triggered_by = [
			aws_cloudfront_public_key.generated_key,
			aws_cloudfront_public_key.kms,
    ]
  }
}

resource "aws_cloudfront_distribution" "distribution" {
	lifecycle {
		replace_triggered_by = [
			aws_cloudfront_key_group.cf_keygroup
    ]
  }
  origin {
    domain_name              = replace(aws_apigatewayv2_api.api.api_endpoint, "/^https?://([^/]*).*/", "$1")
    origin_id                = "signer"
		custom_origin_config {
			http_port = 80
			https_port = 443
			origin_protocol_policy = "https-only"
			origin_ssl_protocols = ["TLSv1.2"]
		}
  }

  enabled             = true
  default_root_object = "index.html"
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class     = "PriceClass_100"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "signer"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }
  ordered_cache_behavior {
    path_pattern     = "/protected/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "signer"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }

		trusted_key_groups     = [aws_cloudfront_key_group.cf_keygroup.id]

    viewer_protocol_policy = "https-only"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "domain" {
  value = aws_cloudfront_distribution.distribution.domain_name
}
