class Provider::Connection < ApplicationRecord
  include Encryptable, Syncable

  self.table_name = "provider_connections"

  belongs_to :family
  belongs_to :provider_family_config, class_name: "Provider::FamilyConfig", optional: true
  has_many :provider_accounts, foreign_key: :provider_connection_id,
                                class_name: "Provider::Account", dependent: :destroy

  if encryption_ready?
    encrypts :credentials
  end

  # Connections only exist when credentials are real — auth flows persist their
  # cross-request state in session (see OauthCallbacksController and
  # PlaidLinkCallbacksController), not in a pending DB row.
  enum :status, { good: "good", requires_update: "requires_update", disconnected: "disconnected" }

  scope :syncable, -> { good.or(requires_update) }

  validates :provider_key, :auth_type, presence: true

  def institution_name
    provider_accounts.first&.raw_payload&.dig("provider", "display_name")&.titleize.presence ||
      provider_key.titleize
  end

  def logo_uri
    provider_accounts.first&.safe_logo_uri
  end

  def pending_setup?
    provider_accounts.unlinked_and_unskipped.exists?
  end

  # Adapter syncer protocol contract: every adapter's syncer class MUST
  # implement #discover_accounts_only — fetch the upstream account list and
  # upsert provider_accounts rows, without syncing transactions or balances.
  # Called after auth credentials are first stored.
  def discover_accounts!
    syncer.discover_accounts_only
  end

  # Polymorphic auth backend dispatch. The adapter declares which auth class
  # handles its credential lifecycle: Provider::Auth::OAuth2 for OAuth providers
  # (TrueLayer, Mercury, etc.), Provider::Auth::EmbeddedLink for Plaid-Link-style
  # providers (Plaid, MX, Yodlee). The auth class accepts (connection) on init.
  def auth
    Provider::ConnectionRegistry.adapter_for(provider_key).auth_class.new(self)
  end

  private

    # Overrides Syncable's default `self.class::Syncer.new(self)` dispatch.
    # Provider::Connection is shared across providers, so we dispatch by provider_key
    # via the registry rather than a hardcoded case statement.
    def syncer
      Provider::ConnectionRegistry.syncer_class_for(provider_key).new(self)
    end

    def sync_broadcaster
      Provider::Connection::SyncCompleteEvent.new(self)
    end
end
