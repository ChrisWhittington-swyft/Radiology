resource "aws_wafv2_web_acl" "main" {
  name  = "waf-${var.tenant_name}-acl-alb"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "waf-block-ipset"
    priority = 0
    action {
      block {}
    }
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.block.arn
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "waf-block-ipset"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = toset(var.rules)
    content {
      name     = rule.value.name
      priority = rule.value.priority
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = rule.value.vendor_name
          dynamic "managed_rule_group_configs" {
            for_each = rule.value.name == "AWSManagedRulesBotControlRuleSet" ? [1] : []
            content {
              aws_managed_rules_bot_control_rule_set {
                inspection_level = "COMMON"
              }
            }
          }
          dynamic "rule_action_override" {
            for_each = rule.value.allow
            content {
              name = rule_action_override.value
              action_to_use {
                allow {}
              }
            }
          }
          dynamic "rule_action_override" {
            for_each = rule.value.block
            content {
              name = rule_action_override.value
              action_to_use {
                block {}
              }
            }
          }
          dynamic "rule_action_override" {
            for_each = rule.value.count
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
          dynamic "rule_action_override" {
            for_each = rule.value.challenge
            content {
              name = rule_action_override.value
              action_to_use {
                challenge {}
              }
            }
          }
          dynamic "rule_action_override" {
            for_each = rule.value.captcha
            content {
              name = rule_action_override.value
              action_to_use {
                captcha {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cw-${var.tenant_name}-waf-alb"
    sampled_requests_enabled   = true
  }
}


resource "aws_wafv2_ip_set" "block" {
  name               = "waf-${var.tenant_name}-block-ipset-alb"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.block_ip_set
}

variable "rules" {
  type = list(any)
  default = [{
    name        = "AWSManagedRulesCommonRuleSet"
    vendor_name = "AWS"
    priority    = 1
    allow = [
      "SizeRestrictions_BODY",
      "GenericRFI_BODY",
      "CrossSiteScripting_BODY"
    ]
    block = [
      "NoUserAgent_HEADER",
      "UserAgent_BadBots_HEADER",
      "SizeRestrictions_QUERYSTRING",
      "SizeRestrictions_Cookie_HEADER",
      "SizeRestrictions_URIPATH",
      "EC2MetaDataSSRF_BODY",
      "EC2MetaDataSSRF_COOKIE",
      "EC2MetaDataSSRF_URIPATH",
      "EC2MetaDataSSRF_QUERYARGUMENTS",
      "GenericLFI_QUERYARGUMENTS",
      "CrossSiteScripting_URIPATH",
      "GenericLFI_URIPATH",
      "GenericLFI_BODY",
      "RestrictedExtensions_URIPATH",
      "RestrictedExtensions_QUERYARGUMENTS",
      "GenericRFI_QUERYARGUMENTS",
      "GenericRFI_URIPATH",
      "CrossSiteScripting_COOKIE",
      "CrossSiteScripting_QUERYARGUMENTS",
    ]
    captcha   = []
    challenge = []
    count     = []
    }, {
    name        = "AWSManagedRulesKnownBadInputsRuleSet"
    vendor_name = "AWS"
    priority    = 5
    allow       = []
    block = [
      "JavaDeserializationRCE_HEADER",
      "JavaDeserializationRCE_BODY",
      "JavaDeserializationRCE_URIPATH",
      "JavaDeserializationRCE_QUERYSTRING",
      "Host_localhost_HEADER",
      "PROPFIND_METHOD",
      "ExploitablePaths_URIPATH",
      "Log4JRCE_HEADER",
      "Log4JRCE_QUERYSTRING",
      "Log4JRCE_BODY",
      "Log4JRCE_URIPATH",
    ]
    captcha   = []
    challenge = []
    count     = []
    }, {
    name        = "AWSManagedRulesBotControlRuleSet"
    vendor_name = "AWS"
    priority    = 6
    allow = [
      "SignalAutomatedBrowser",
      "CategoryHttpLibrary",
      "SignalNonBrowserUserAgent"
    ]
    block     = []
    captcha   = []
    challenge = []
    count = [
      "CategoryAdvertising",
      "CategoryArchiver",
      "CategoryContentFetcher",
      "CategoryEmailClient",
      "CategoryLinkChecker",
      "CategoryMiscellaneous",
      "CategoryMonitoring",
      "CategoryScrapingFramework",
      "CategorySearchEngine",
      "CategorySecurity",
      "CategorySeo",
      "CategorySocialMedia",
      "CategoryAI",
      "SignalKnownBotDataCenter"
    ]
    }
  ]
}


variable "name" {
  default     = "resource"
  type        = string
}

variable "block_ip_set" {
  default     = []
  type        = list(string)
  description = "List of IP to block"
}

###=================== CloudWatch Group Logging =================== ###

resource "aws_wafv2_web_acl_logging_configuration" "waf_logging_configuration" {
  log_destination_configs = [aws_cloudwatch_log_group.wafv2-log-group.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
  depends_on              = [aws_cloudwatch_log_group.wafv2-log-group]
}

resource "aws_cloudwatch_log_group" "wafv2-log-group" {
  name              = "aws-waf-logs-waf"
  retention_in_days = 90
}