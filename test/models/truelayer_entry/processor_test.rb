require "test_helper"

class TruelayerEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family  = families(:dylan_family)
    @account = accounts(:depository)

    @truelayer_item = TruelayerItem.create!(
      family:        @family,
      name:          "Test TrueLayer",
      client_id:     "test_client",
      client_secret: "test_secret"
    )
    @truelayer_account = TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_acc_001",
      account_kind:   "account",
      name:           "Current Account",
      currency:       "GBP"
    )
    AccountProvider.create!(account: @account, provider: @truelayer_account)
  end

  test "creates entry from settled transaction" do
    tx = {
      transaction_id: "txn_abc123",
      timestamp:      "2026-01-15T10:30:00Z",
      amount:         -25.50,
      currency:       "GBP",
      transaction_type: "DEBIT",
      merchant_name:  "Tesco",
      description:    "TESCO STORES 6543"
    }

    assert_difference "@account.entries.count", 1 do
      TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    end

    entry = @account.entries.find_by!(external_id: "truelayer_txn_abc123", source: "truelayer")
    assert_equal 25.50, entry.amount.to_f.abs
    assert_equal "GBP", entry.currency
    assert_equal "2026-01-15", entry.date.to_s
  end

  test "uses merchant_name as name" do
    tx = {
      transaction_id: "txn_merch",
      timestamp:      Date.current.iso8601,
      amount:         -10.00,
      currency:       "GBP",
      transaction_type: "DEBIT",
      merchant_name:  "Starbucks",
      description:    "SBX*LONDON BRIDGE"
    }

    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_merch")
    assert_equal "Starbucks", entry.name
  end

  test "falls back to description when merchant_name is blank" do
    tx = {
      transaction_id: "txn_nodesc",
      timestamp:      Date.current.iso8601,
      amount:         -5.00,
      currency:       "GBP",
      transaction_type: "DEBIT",
      merchant_name:  nil,
      description:    "BANK TRANSFER"
    }

    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_nodesc")
    assert_equal "BANK TRANSFER", entry.name
  end

  test "does not create duplicate for same transaction_id" do
    tx = {
      transaction_id: "txn_dup",
      timestamp:      Date.current.iso8601,
      amount:         -50.00,
      currency:       "GBP",
      transaction_type: "DEBIT",
      description:    "Test"
    }

    assert_difference "@account.entries.count", 1 do
      TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    end
    assert_no_difference "@account.entries.count" do
      TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    end
  end

  test "raises ArgumentError when transaction_id is blank" do
    tx = { transaction_id: nil, timestamp: Date.current.iso8601, amount: -10.0, currency: "GBP", transaction_type: "DEBIT" }

    assert_raises(ArgumentError) do
      TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    end
  end

  test "stores pending true in extra for pending transactions" do
    tx = {
      transaction_id: "txn_pend",
      timestamp:      Date.current.iso8601,
      amount:         -8.00,
      currency:       "GBP",
      transaction_type: "DEBIT",
      description:    "Pending payment",
      _pending:       true
    }

    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_pend")
    assert_equal true, entry.transaction&.extra&.dig("truelayer", "pending")
  end

  test "stores pending false in extra for settled transactions so stale pending flag is overwritten" do
    tx = {
      transaction_id:   "txn_settled",
      timestamp:        Date.current.iso8601,
      amount:           -12.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      description:      "Settled payment"
    }

    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_settled")
    assert_equal false, entry.transaction&.extra&.dig("truelayer", "pending")
  end

  test "skips when no linked account" do
    unlinked = TruelayerAccount.create!(
      truelayer_item: @truelayer_item,
      account_id:     "tl_acc_unlinked",
      account_kind:   "account",
      name:           "Unlinked",
      currency:       "GBP"
    )
    tx = { transaction_id: "txn_skip", timestamp: Date.current.iso8601, amount: -1.0, currency: "GBP", transaction_type: "DEBIT", description: "X" }

    assert_no_difference "Entry.count" do
      TruelayerEntry::Processor.new(tx, truelayer_account: unlinked).process
    end
  end

  test "falls back to TrueLayer Transaction when both merchant_name and description are blank" do
    tx = {
      transaction_id:   "txn_noname",
      timestamp:        Date.current.iso8601,
      amount:           -3.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      merchant_name:    nil,
      description:      nil
    }
    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_noname")
    assert_equal "TrueLayer Transaction", entry.name
  end

  test "stores CREDIT transaction with negative amount" do
    tx = {
      transaction_id:   "txn_credit",
      timestamp:        Date.current.iso8601,
      amount:           50.00,
      currency:         "GBP",
      transaction_type: "CREDIT",
      description:      "Salary"
    }
    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_credit")
    assert entry.amount.negative?, "CREDIT transaction should have negative amount"
  end

  test "raises when timestamp is invalid rather than silently importing with today's date" do
    tx = {
      transaction_id:   "txn_baddate",
      timestamp:        "not-a-date",
      amount:           -10.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      description:      "Bad timestamp"
    }

    assert_raises(ArgumentError) do
      TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    end
  end

  test "raises when timestamp is blank rather than silently importing with today's date" do
    tx = {
      transaction_id:   "txn_nodate",
      timestamp:        nil,
      amount:           -10.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      description:      "No timestamp"
    }

    assert_raises(ArgumentError) do
      TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    end
  end

  test "settled transaction matches pending by amount/date when transaction_id changes on settle" do
    pending_tx = {
      transaction_id:   "txn_pending_001",
      timestamp:        Date.current.iso8601,
      amount:           -25.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      description:      "Costa Coffee",
      _pending:         true
    }
    TruelayerEntry::Processor.new(pending_tx, truelayer_account: @truelayer_account).process

    settled_tx = {
      transaction_id:   "txn_settled_001",
      timestamp:        Date.current.iso8601,
      amount:           -25.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      description:      "Costa Coffee"
    }

    assert_no_difference "@account.entries.count" do
      TruelayerEntry::Processor.new(settled_tx, truelayer_account: @truelayer_account).process
    end

    entry = @account.entries.find_by!(source: "truelayer")
    assert_not entry.transaction.pending?, "should no longer be pending after settle"
  end

  test "marks transaction pending when transaction_status is PENDING on settled endpoint" do
    tx = {
      transaction_id:   "txn_status_pend",
      timestamp:        Date.current.iso8601,
      amount:           -15.00,
      currency:         "GBP",
      transaction_type: "DEBIT",
      description:      "Card authorisation",
      transaction_status: "PENDING"
    }

    TruelayerEntry::Processor.new(tx, truelayer_account: @truelayer_account).process
    entry = @account.entries.find_by!(external_id: "truelayer_txn_status_pend")
    assert_not_nil entry
    assert entry.transaction&.pending?, "Transaction with transaction_status: PENDING should be marked pending"
  end
end
