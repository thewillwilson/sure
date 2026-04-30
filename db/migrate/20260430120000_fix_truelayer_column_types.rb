class FixTruelayerColumnTypes < ActiveRecord::Migration[7.2]
  def up
    # sync_start_date is a date-only field; datetime was unnecessarily precise
    change_column :truelayer_items, :sync_start_date, :date
    # last_psu_ip needs text for AR Encryption overhead
    change_column :truelayer_items, :last_psu_ip, :text
    # raw_payload stores the raw API response string, not structured JSON
    change_column :truelayer_accounts, :raw_payload, :text, using: "raw_payload::text"
  end

  def down
    change_column :truelayer_items, :sync_start_date, :datetime
    change_column :truelayer_items, :last_psu_ip, :string
    change_column :truelayer_accounts, :raw_payload, :jsonb, using: "raw_payload::jsonb"
  end
end
