class RemoveUniqueIndexFromTruelayerItemsClientId < ActiveRecord::Migration[7.2]
  def change
    remove_index :truelayer_items, name: "idx_truelayer_items_on_family_and_client_id"
  end
end
