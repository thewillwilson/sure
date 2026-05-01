class TruelayerItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :client_id,     deterministic: true
    encrypts :client_secret
    encrypts :access_token
    encrypts :refresh_token
  end

  validates :name,          presence: true
  validates :client_id,     presence: true
  validates :client_secret, presence: true, on: :create

  belongs_to :family

  has_many :truelayer_accounts, dependent: :destroy
  has_many :accounts, through: :truelayer_accounts

  scope :active,       -> { where(scheduled_for_deletion: false) }
  scope :syncable,     -> { active.where(status: :good).where.not(access_token: nil) }
  scope :ordered,      -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_truelayer_data(balances_only: false)
    unless credentials_configured?
      Rails.logger.error "TruelayerItem #{id} - Cannot import: TrueLayer token not configured"
      raise StandardError.new("TrueLayer token not configured")
    end

    refresh_tokens! if token_expired?

    unless token_valid?
      Rails.logger.error "TruelayerItem #{id} - Cannot import: TrueLayer token invalid — re-authorization required"
      raise StandardError.new("TrueLayer token invalid — re-authorization required")
    end

    TruelayerItem::Importer.new(self).import(balances_only: balances_only)
  rescue => e
    Rails.logger.error "TruelayerItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def consent_expiring_soon?
    consent_expires_at.present? && consent_expires_at <= 7.days.from_now
  end

  def institution_name
    truelayer_accounts.filter_map(&:provider_display_name).first
  end

  def display_name
    institution_name || name
  end

  def linked_accounts_count
    truelayer_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    truelayer_accounts.left_joins(:account_provider).where(account_providers: { id: nil }, setup_skipped: false).count
  end

  def skipped_accounts_count
    truelayer_accounts.left_joins(:account_provider).where(account_providers: { id: nil }, setup_skipped: true).count
  end

  def total_accounts_count
    truelayer_accounts.count
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync:        parent_sync,
          window_start_date:  window_start_date,
          window_end_date:    window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "TruelayerItem #{id} — failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end
end
