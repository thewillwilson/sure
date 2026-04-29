class Provider::TruelayerAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("TruelayerAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_truelayer?

    [ {
      key:                  "truelayer",
      name:                 "TrueLayer",
      description:          "Connect UK and European bank accounts via TrueLayer Open Banking",
      can_connect:          true,
      new_account_path:     ->(_accountable_type, _return_to) {
        Rails.application.routes.url_helpers.new_truelayer_item_path
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_truelayer_items_path(account_id: account_id)
      }
    } ]
  end

  def provider_name
    "truelayer"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_truelayer_item_path(item)
  end

  def item
    provider_account.truelayer_item
  end

  def can_delete_holdings?
    false
  end

  def institution_name
    provider_account.provider_display_name || item&.name
  end

  def logo_url
    nil
  end
end
