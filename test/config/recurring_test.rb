require "test_helper"

# A light, string-level check that the nightly OAuth cleanup job is actually
# registered in solid_queue's recurring-task configuration -- catches the class
# of bug where the job exists and is tested, but nobody wired it to run.
class RecurringConfigTest < ActiveSupport::TestCase
  test "the production recurring schedule references OauthCleanupJob" do
    config = File.read(Rails.root.join("config/recurring.yml"))

    assert_includes config, "OauthCleanupJob"
  end
end
