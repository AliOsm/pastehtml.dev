require "test_helper"

class McpTools::GetPasteStatsTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
    @paste = Paste.create!(content: "<p>x</p>", original_filename: "paste.html", user: @alice)
  end

  test "views_by_source is zero-filled across every source" do
    record_view!(source: "show")
    record_view!(source: "raw")

    response = stats(token: @paste.token)

    assert_not response.error?
    by_source = response.structured_content[:views_by_source]
    assert_equal({ show: 1, live: 0, raw: 1, render: 0 }, by_source)
  end

  test "views_count reflects the total across every source, including views outside the recent window" do
    record_view!(source: "show", created_at: 40.days.ago)
    record_view!(source: "raw")
    record_view!(source: "live")

    response = stats(token: @paste.token)

    assert_equal 3, response.structured_content[:views_count]
    assert_equal 1, response.structured_content[:views_by_source][:show]
  end

  test "recent_views aggregates by day for the last 30 days and omits older days" do
    today = Date.current
    yesterday = today - 1
    record_view!(source: "show", created_at: today.in_time_zone.noon)
    record_view!(source: "raw", created_at: today.in_time_zone.noon)
    record_view!(source: "show", created_at: yesterday.in_time_zone.noon)
    record_view!(source: "show", created_at: 40.days.ago)

    response = stats(token: @paste.token)

    recent = response.structured_content[:recent_views]
    today_entry = recent.find { |entry| entry[:date] == today.iso8601 }
    yesterday_entry = recent.find { |entry| entry[:date] == yesterday.iso8601 }

    assert_equal 2, today_entry[:count]
    assert_equal 1, yesterday_entry[:count]
    assert_not recent.any? { |entry| entry[:date] == 40.days.ago.to_date.iso8601 }
  end

  test "never returns referrers, user agents, or IPs" do
    record_view!(source: "show", referrer: "https://evil.example/track", user_agent: "SecretBrowser/1.0")

    response = stats(token: @paste.token)

    payload_json = JSON.generate(response.structured_content)
    assert_not_includes payload_json, "evil.example"
    assert_not_includes payload_json, "SecretBrowser"
    assert_not response.structured_content.to_s.match?(/referrer|user_agent|ip_address/i)
  end

  test "a token belonging to another user is a not-found error" do
    theirs = Paste.create!(content: "<p>bob's</p>", original_filename: "paste.html", user: @bob)

    response = stats(token: theirs.token)

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
    assert_equal "token", response.structured_content[:field]
  end

  test "an unknown token is a not-found error" do
    response = stats(token: "does-not-exist")

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
  end

  test "annotations mark it read-only, idempotent, non-destructive, closed-world" do
    annotations = McpTools::GetPasteStats.annotations_value

    assert_equal true, annotations.read_only_hint
    assert_equal false, annotations.destructive_hint
    assert_equal true, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def stats(**args)
      McpTools::GetPasteStats.call(**args, server_context: @ctx)
    end

    def record_view!(source:, created_at: Time.current, referrer: nil, user_agent: nil)
      PasteView.create!(
        paste: @paste,
        source: source,
        created_at: created_at,
        updated_at: created_at,
        referrer: referrer,
        user_agent: user_agent
      )
    end
end
