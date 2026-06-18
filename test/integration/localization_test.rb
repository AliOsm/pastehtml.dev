require "test_helper"

# Guards the Arabic localization: that ar.yml stays structurally in lockstep
# with en.yml, that placeholders survive translation, and that pages actually
# render in Arabic (not silently falling back to English).
class LocalizationTest < ActionDispatch::IntegrationTest
  EN = YAML.load_file(Rails.root.join("config/locales/en.yml")).fetch("en")
  AR = YAML.load_file(Rails.root.join("config/locales/ar.yml")).fetch("ar")

  test "ar.yml defines exactly the same keys as en.yml" do
    assert_equal leaf_keys(EN), leaf_keys(AR),
      "Locale key sets drifted.\n  only in en: #{(leaf_keys(EN) - leaf_keys(AR)).sort}\n  only in ar: #{(leaf_keys(AR) - leaf_keys(EN)).sort}"
  end

  test "every interpolation placeholder is preserved in Arabic" do
    each_leaf(EN) do |key, english|
      next unless english.is_a?(String)
      arabic = dig(AR, key)
      assert_equal placeholders(english), placeholders(arabic),
        "%{...} placeholders differ for #{key.join('.')}: en=#{english.inspect} ar=#{arabic.inspect}"
    end
  end

  test "the Arabic copy is actually Arabic, not an English fallback" do
    # A representative sample of human-facing copy must differ from English.
    %w[home.subtitle home.features.instant.title show.live_title flash.choose_file].each do |key|
      assert_not_equal I18n.t(key, locale: :en), I18n.t(key, locale: :ar),
        "#{key} still reads as English — Arabic translation is missing"
    end
  end

  test "the home page renders right-to-left in Arabic" do
    get root_url, headers: { "Cookie" => "locale=ar" }

    assert_response :success
    assert_select "html[lang=ar][dir=rtl]"
    assert_includes response.body, I18n.t("home.features.instant.title", locale: :ar)
    assert_not_includes response.body, "translation missing"
  end

  test "the result page renders right-to-left in Arabic" do
    get paste_url(pastes(:hello)), headers: { "Cookie" => "locale=ar" }

    assert_response :success
    assert_select "html[lang=ar][dir=rtl]"
    assert_includes response.body, I18n.t("show.share.label", locale: :ar)
    assert_not_includes response.body, "translation missing"
  end

  test "flash messages localize to Arabic" do
    post pastes_url, headers: { "Cookie" => "locale=ar" }

    assert_redirected_to root_url
    assert_equal I18n.t("flash.choose_file", locale: :ar), flash[:alert]
  end

  test "dates localize to Arabic month names" do
    assert_equal "18 يونيو 2026", I18n.l(Date.new(2026, 6, 18), format: :long, locale: :ar)
  end

  private
    def leaf_keys(node, prefix = [])
      case node
      when Hash then node.flat_map { |k, v| leaf_keys(v, prefix + [ k ]) }
      else [ prefix.join(".") ]
      end
    end

    def each_leaf(node, prefix = [], &block)
      node.each do |k, v|
        v.is_a?(Hash) ? each_leaf(v, prefix + [ k ], &block) : block.call(prefix + [ k ], v)
      end
    end

    def dig(node, key) = key.reduce(node) { |n, k| n.is_a?(Hash) ? n[k] : nil }

    def placeholders(value) = value.to_s.scan(/%\{[^}]+\}/).sort
end
