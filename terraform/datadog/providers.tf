# Credentials are never declared as variables: the provider reads DD_API_KEY
# and DD_APP_KEY from the environment, so no key can end up in a tfvars file
# or in the state.
provider "datadog" {
  api_url = var.datadog_api_url
}
