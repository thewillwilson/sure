class AddConsentExpiresAtToTruelayerItems < ActiveRecord::Migration[7.2]
  def change
    add_column :truelayer_items, :consent_expires_at, :datetime
  end
end
