class AddUniqueIndexToTruelayerItemsClientId < ActiveRecord::Migration[7.2]
  def up
    # Mark older duplicates as scheduled_for_deletion so they fall outside the
    # partial index scope (client_id IS NOT NULL AND scheduled_for_deletion = false).
    # This preserves referential integrity with truelayer_accounts.
    execute <<~SQL
      UPDATE truelayer_items
      SET scheduled_for_deletion = true
      WHERE id IN (
        SELECT id FROM (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY family_id, client_id
                   ORDER BY created_at DESC
                 ) AS rn
          FROM truelayer_items
          WHERE client_id IS NOT NULL
            AND scheduled_for_deletion = false
        ) ranked
        WHERE rn > 1
      )
    SQL

    add_index :truelayer_items, [ :family_id, :client_id ],
              unique: true,
              where:  "client_id IS NOT NULL AND scheduled_for_deletion = false",
              name:   "idx_truelayer_items_on_family_and_client_id"
  end

  def down
    remove_index :truelayer_items, name: "idx_truelayer_items_on_family_and_client_id"
    raise ActiveRecord::IrreversibleMigration,
      "Data fixup (scheduled_for_deletion updates) cannot be automatically reversed."
  end
end
