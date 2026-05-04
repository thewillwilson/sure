# Connection-framework adapter for Plaid (US + EU regions).
#
# Registered twice with Provider::ConnectionRegistry — once per region — so
# that "plaid_us" and "plaid_eu" are distinct provider_keys with separate
# bank-sync directory entries, but the adapter logic is shared. Region is
# stored on connection.metadata["region"] and consulted when the adapter
# needs to pick the right Provider::Plaid client.
#
# This is the new framework-side adapter; the legacy Provider::PlaidAdapter
# (per-account adapter registered with Provider::Factory) continues to serve
# existing PlaidItem rows during the cutover. The legacy adapter's
# .connection_configs returns [] so the bank-sync directory only shows the
# new entry.
class Provider::Plaid::Adapter
  extend Provider::ConnectionAdapter

  # Plaid type → Sure Accountable mapping.
  # https://plaid.com/docs/api/accounts/#account-type-schema
  TYPE_MAPPING = {
    "depository" => { accountable: Depository, subtype_mapping: {
      "checking" => "checking", "savings" => "savings", "hsa" => "hsa",
      "cd" => "cd", "money market" => "money_market"
    } },
    "credit" => { accountable: CreditCard, subtype_mapping: {
      "credit card" => "credit_card"
    } },
    "loan" => { accountable: Loan, subtype_mapping: {
      "mortgage" => "mortgage", "student" => "student", "auto" => "auto",
      "business" => "business", "home equity" => "home_equity",
      "line of credit" => "line_of_credit"
    } },
    "investment" => { accountable: Investment, subtype_mapping: {
      "brokerage" => "brokerage", "pension" => "pension", "retirement" => "retirement",
      "401k" => "401k", "roth 401k" => "roth_401k", "403b" => "403b", "457b" => "457b",
      "529" => "529_plan", "hsa" => "hsa", "mutual fund" => "mutual_fund",
      "roth" => "roth_ira", "ira" => "ira", "sep ira" => "sep_ira",
      "simple ira" => "simple_ira", "trust" => "trust", "ugma" => "ugma", "utma" => "utma"
    } }
  }.freeze

  def self.display_name = "Plaid"
  def self.description  = "Connect US and EU banks via Plaid"
  def self.brand_color  = "#000000"
  def self.beta?        = false

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.syncer_class          = Provider::Plaid::Syncer
  def self.auth_class            = Provider::Auth::EmbeddedLink
  def self.webhook_handler_class = Provider::Plaid::WebhookHandler

  # Plaid signs webhooks with a JWT in the Plaid-Verification header and
  # publishes the verification key via /webhook_verification_key/get. The
  # existing Provider::Plaid#validate_webhook! does the work; we just route
  # to the right region's client.
  def self.verify_webhook!(headers:, raw_body:)
    sig = headers["Plaid-Verification"] || headers["HTTP_PLAID_VERIFICATION"]
    raise Provider::Plaid::Adapter::WebhookSignatureMissing, "missing Plaid-Verification header" if sig.blank?

    region = headers["X-Provider-Region"] || extract_region_from_body(raw_body)
    Provider::Registry.plaid_provider_for_region(region).validate_webhook!(sig, raw_body)
  end

  WebhookSignatureMissing = Class.new(StandardError)

  # Plaid's webhook payload doesn't carry the region, so we infer it from the
  # connection (looking up by item_id). If that fails we default to :us — the
  # signature check would fail anyway if the wrong region's keys were used.
  def self.extract_region_from_body(raw_body)
    parsed = JSON.parse(raw_body) rescue {}
    item_id = parsed["item_id"]
    return :us if item_id.blank?
    conn = Provider::Connection.where("metadata->>'plaid_item_id' = ?", item_id).first
    (conn&.metadata&.[]("region") || "us").to_sym
  end

  # Returns both regional configs (US and EU) on every call — the adapter is
  # registered twice (plaid_us + plaid_eu) so ConnectionRegistry calls this
  # once per key. ConnectionRegistry.all_connection_configs dedupes by
  # config[:key], so the bank-sync directory ends up with each region listed
  # once regardless of how many registrations point here.
  def self.connection_configs(family:)
    configs = []
    if Provider::Registry.plaid_provider_for_region(:us).present?
      configs << {
        key:  "plaid_us",
        name: "Plaid",
        description: "Connect to your US bank via Plaid",
        new_account_path: ->(_accountable_type, _return_to) {
          Rails.application.routes.url_helpers.new_embedded_link_callbacks_path(provider_key: "plaid_us", region: "us")
        },
        existing_account_path: nil
      }
    end
    if Provider::Registry.plaid_provider_for_region(:eu).present?
      configs << {
        key:  "plaid_eu",
        name: "Plaid (EU)",
        description: "Connect to your EU bank via Plaid",
        new_account_path: ->(_accountable_type, _return_to) {
          Rails.application.routes.url_helpers.new_embedded_link_callbacks_path(provider_key: "plaid_eu", region: "eu")
        },
        existing_account_path: nil
      }
    end
    configs
  end

  def self.build_sure_account(provider_account, family:)
    type    = provider_account.external_type.to_s
    subtype = provider_account.external_subtype.to_s
    mapping = TYPE_MAPPING[type] ||
      raise(Provider::Account::UnsupportedAccountableType,
            "Provider::Plaid::Adapter does not handle external_type=#{type.inspect}")

    accountable_subtype = mapping[:subtype_mapping][subtype] || "other"
    accountable = mapping[:accountable].new(subtype: accountable_subtype)

    family.accounts.build(
      name:        provider_account.external_name,
      currency:    provider_account.currency,
      balance:     0,
      accountable: accountable
    )
  end

  # ---- EmbeddedLink contract --------------------------------------------

  def self.js_controller_name = "plaid"

  def self.start_link_flow(family:, flow_id:, params:, resume_url:, webhooks_url:)
    if params[:connection_id].present?
      connection = family.provider_connections.find(params[:connection_id])
      region = connection.metadata["region"]
      kind = "update"
      access_token = connection.credentials["access_token"]
    else
      region = params[:region].to_s
      raise ArgumentError, "Unknown region: #{region.inspect}" unless %w[us eu].include?(region)
      kind = "new"
      access_token = nil
    end

    link_token = Provider::Registry.plaid_provider_for_region(region.to_sym).get_link_token(
      user_id:          family.id,
      webhooks_url:     webhooks_url,
      redirect_url:     resume_url,
      accountable_type: params[:accountable_type],
      access_token:     access_token
    ).link_token

    state = {
      "kind"       => kind,
      "region"     => region,
      "link_token" => link_token,
      "created_at" => Time.current.to_i
    }
    state["connection_id"] = connection.id if kind == "update"
    state
  end

  def self.complete_link_flow(family:, flow:, params:)
    region = flow["region"]
    response = Provider::Registry.plaid_provider_for_region(region.to_sym)
                                  .exchange_public_token(params.require(:public_token))

    Provider::Connection.transaction do
      conn = family.provider_connections.create!(
        provider_key: "plaid_#{region}",
        auth_type:    "embedded_link",
        status:       :good,
        credentials:  {},
        metadata: {
          "region"        => region,
          "plaid_item_id" => response.item_id
        }
      )
      conn.auth.store_access_token(response.access_token)
      conn
    end
  end

  def self.js_data_for(flow:, is_resume:)
    {
      controller:                "plaid",
      plaid_link_token_value:    flow["link_token"],
      plaid_region_value:        flow["region"],
      plaid_is_update_value:     flow["kind"] == "update",
      plaid_is_resume_value:     is_resume,
      plaid_flow_id_value:       flow["__flow_id"], # set by the controller before render
      plaid_connection_id_value: flow["connection_id"]
    }
  end
end

Provider::ConnectionRegistry.register("plaid_us", Provider::Plaid::Adapter)
Provider::ConnectionRegistry.register("plaid_eu", Provider::Plaid::Adapter)
