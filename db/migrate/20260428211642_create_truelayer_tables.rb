class CreateTruelayerTables < ActiveRecord::Migration[7.2]
  def change
    create_table :truelayer_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      # Per-family TrueLayer developer credentials
      t.text :client_id
      t.text :client_secret

      # OAuth2 tokens (text to accommodate JWT length + AR Encryption overhead)
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at

      # Sandbox vs production
      t.boolean :sandbox, default: false, null: false

      # PSU IP for rate-limit bypass (stored at sync trigger time)
      t.string :last_psu_ip

      # Sync window
      t.datetime :sync_start_date

      t.timestamps
    end

    add_index :truelayer_items, :status

    create_table :truelayer_accounts, id: :uuid do |t|
      t.references :truelayer_item, null: false, foreign_key: true, type: :uuid

      t.string :account_id, null: false
      t.string :account_kind, null: false   # "account" (debit) or "card" (credit)
      t.string :name, null: false
      t.string :account_type   # TRANSACTION, SAVINGS, BUSINESS_TRANSACTION, BUSINESS_SAVINGS
      t.string :currency, null: false
      t.boolean :setup_skipped, default: false, null: false
      t.jsonb   :raw_payload

      t.timestamps
    end

    add_index :truelayer_accounts, [ :truelayer_item_id, :account_id ], unique: true, name: "idx_truelayer_accounts_on_item_and_account_id"
    add_index :truelayer_accounts, :account_id
  end
end
