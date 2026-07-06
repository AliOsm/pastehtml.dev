require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  PAGES = { making_of: "Making of", lock_it_up: "Lock It Up", mark_it_down: "Mark It Down" }.freeze

  test "each guide renders its own content inside the shared app layout" do
    PAGES.each do |action, title|
      get public_send("#{action}_path")

      assert_response :success
      # The page's scoped content sits inside the app layout's <main id="main">,
      # which proves the shared chrome (header/footer) wraps it -- not the page's own.
      assert_select "main#main div.vanity-page"
      assert_select "title", /#{title}/i
    end
  end

  test "each guide has a top-level heading for a valid document outline" do
    PAGES.each_key do |action|
      get public_send("#{action}_path")

      assert_select "div.vanity-page h1", minimum: 1, message: "#{action} needs an <h1>"
    end
  end

  test "the lock-it-up guide ships its client-side encryption forge" do
    get lock_it_up_path

    assert_response :success
    assert_includes response.body, "crypto.subtle"
  end

  test "the mark-it-down guide ships its client-side markdown forge" do
    get mark_it_down_path

    assert_response :success
    assert_includes response.body, "DOMPurify"
  end

  test "legacy vanity subdomains redirect permanently to their in-app path" do
    Paste::VANITY_PAGE_SUBDOMAINS.each do |slug|
      host! "#{slug}.example.com"
      get "/"

      assert_response :moved_permanently
      assert_redirected_to "http://example.com/#{slug}"
    end
  end

  test "each guide follows the app locale instead of an in-page toggle" do
    PAGES.each_key do |action|
      path = public_send("#{action}_path")

      get path
      assert_select ".lang-toggle", false, "#{action} must not ship its own language switcher"
      assert_select "#en:not([hidden])"
      assert_select "#ar[dir='rtl'][hidden]" # Arabic block present, RTL, hidden under English

      get path, headers: { "Accept-Language" => "ar" }
      assert_select "#ar:not([hidden])"
      assert_select "#en[hidden]"
    end
  end
end
