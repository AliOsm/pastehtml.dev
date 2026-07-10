require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test "filters OAuth codes and MCP tool-call content" do
    # Rails' `config.precompile_filter_parameters` (on by default) rewrites
    # config.filter_parameters in place into compiled Regexp objects the
    # first time any request is dispatched, so depending on test order the
    # raw :code / :content symbols may already be folded into a Regexp by
    # the time this runs. Compare against the stringified form instead of
    # asserting on the raw array so this doesn't depend on that timing.
    described = Rails.application.config.filter_parameters.map(&:to_s).join("|")

    assert_match(/code/, described)
    assert_match(/content/, described)
  end

  test "actually redacts code, code_verifier, and content values" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter(code: "x", code_verifier: "y", content: "z")

    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered[:code]
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered[:code_verifier]
    assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered[:content]
  end
end
