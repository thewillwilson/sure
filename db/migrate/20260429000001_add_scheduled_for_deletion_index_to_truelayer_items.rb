class AddScheduledForDeletionIndexToTruelayerItems < ActiveRecord::Migration[7.2]
  def change
    add_index :truelayer_items, :scheduled_for_deletion
  end
end
