require "test_helper"

class SyncHourlyJobTest < ActiveJob::TestCase
  test "syncs all syncable items for each hourly syncable class" do
    SyncHourlyJob::HOURLY_SYNCABLES.each do |klass|
      mock_item = mock("#{klass.name.underscore}_item")
      mock_item.expects(:sync_later).once

      mock_relation = mock("syncable_relation")
      mock_relation.stubs(:find_each).yields(mock_item)

      klass.expects(:syncable).returns(mock_relation)
    end

    SyncHourlyJob.perform_now
  end

  test "continues syncing other items when one fails" do
    failing_item = mock("failing_item")
    failing_item.expects(:sync_later).raises(StandardError.new("Test error"))
    failing_item.stubs(:id).returns(1)

    success_item = mock("success_item")
    success_item.expects(:sync_later).once

    mock_relation = mock("syncable_relation")
    mock_relation.stubs(:find_each).multiple_yields([ failing_item ], [ success_item ])

    CoinstatsItem.expects(:syncable).returns(mock_relation)
    TruelayerItem.expects(:syncable).returns(stub(find_each: nil))

    assert_nothing_raised do
      SyncHourlyJob.perform_now
    end
  end
end
