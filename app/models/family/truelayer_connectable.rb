module Family::TruelayerConnectable
  extend ActiveSupport::Concern

  included do
    has_many :truelayer_items, dependent: :destroy
  end

  def can_connect_truelayer?
    true
  end
end
