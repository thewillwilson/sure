# frozen_string_literal: true

module TruelayerItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    truelayer_accounts.find_each do |ta|
      links    = AccountProvider.where(provider_type: "TruelayerAccount", provider_id: ta.id).to_a
      link_ids = links.map(&:id)
      result   = { ta_id: ta.id, name: ta.name, provider_link_ids: link_ids }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
          links.each(&:destroy!)
        end
      rescue => e
        Rails.logger.warn("TruelayerItem Unlinker: failed to unlink TA ##{ta.id}: #{e.class} - #{e.message}")
        result[:error] = e.message
      end
    end

    results
  end
end
