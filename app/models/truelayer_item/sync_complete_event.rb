class TruelayerItem::SyncCompleteEvent
  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def broadcast
    truelayer_item.reload

    truelayer_item.accounts.each(&:broadcast_sync_complete)

    family = truelayer_item.family
    return unless family

    truelayer_item.broadcast_replace_to(
      family,
      target:  "truelayer_item_#{truelayer_item.id}",
      partial: "truelayer_items/truelayer_item",
      locals:  { truelayer_item: truelayer_item }
    )

    truelayer_items = family.truelayer_items.ordered.includes(:syncs)
    truelayer_item.broadcast_replace_to(
      family,
      target:  "truelayer-providers-panel",
      partial: "settings/providers/truelayer_panel",
      locals:  { truelayer_items: truelayer_items, family: family }
    )

    family.broadcast_sync_complete unless truelayer_item.pending_account_setup?
  end
end
