require "test_helper"

class BatchUploadTest < ActiveSupport::TestCase
  test "still processing while reviews remain outstanding" do
    batch = BatchUpload.create!(total_count: 3, completed_count: 1, failed_count: 0)
    batch.update_status!
    assert_equal "processing", batch.status
  end

  test "complete when every review succeeded" do
    batch = BatchUpload.create!(total_count: 3, completed_count: 3, failed_count: 0)
    batch.update_status!
    assert_equal "complete", batch.status
  end

  test "partial when some reviews failed but not all" do
    batch = BatchUpload.create!(total_count: 3, completed_count: 1, failed_count: 2)
    batch.update_status!
    assert_equal "partial", batch.status
  end

  test "failed when every review failed" do
    batch = BatchUpload.create!(total_count: 2, completed_count: 0, failed_count: 2)
    batch.update_status!
    assert_equal "failed", batch.status
  end

  test "active? reflects pending and processing states" do
    assert BatchUpload.new(status: "pending").active?
    assert BatchUpload.new(status: "processing").active?
    refute BatchUpload.new(status: "complete").active?
  end

  test "progress_label reports finished over total" do
    batch = BatchUpload.new(total_count: 10, completed_count: 6, failed_count: 1)
    assert_equal "7 / 10 complete", batch.progress_label
  end
end
