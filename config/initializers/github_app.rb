# GitHub App Configuration
#
# This initializer loads and validates GitHub App credentials if they are configured.
# The app can be used with these environment variables or Rails credentials:
#
# Environment variables:
#   GITHUB_APP_ID - Numeric app ID from GitHub
#   GITHUB_APP_PRIVATE_KEY - PEM-formatted private key
#   GITHUB_APP_INSTALLATION_ID - (optional) Pre-configured installation ID
#
# Rails credentials (config/credentials.yml):
#   github_app:
#     id: <numeric-app-id>
#     private_key: |
#       -----BEGIN RSA PRIVATE KEY-----
#       ...
#       -----END RSA PRIVATE KEY-----
#
# If both environment variables and Rails credentials are present,
# environment variables take precedence.

if Rails.env.production? || ENV["GITHUB_APP_ID"].present?
  begin
    app_id = ENV["GITHUB_APP_ID"] || Rails.application.credentials.dig(:github_app, :id)
    if app_id.blank?
      Rails.logger.warn "GitHub App credentials not configured. GitHub operations may fail. Set GITHUB_APP_ID or github_app.id in credentials."
    else
      Rails.logger.info "GitHub App configured with ID: #{app_id}"
    end
  rescue => e
    Rails.logger.error "Error loading GitHub App credentials: #{e.message}"
  end
end
