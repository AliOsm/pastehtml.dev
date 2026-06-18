require "test_helper"

class LocaleSwitchingTest < ActionDispatch::IntegrationTest
  test "defaults to English with an ltr direction" do
    get root_url

    assert_response :success
    assert_select "html[lang=en][dir=ltr]"
  end

  test "honors an Arabic Accept-Language header on the first visit" do
    get root_url, headers: { "Accept-Language" => "ar,en;q=0.8" }

    assert_select "html[lang=ar][dir=rtl]"
  end

  test "picks the first available locale listed in Accept-Language" do
    get root_url, headers: { "Accept-Language" => "fr-FR,fr;q=0.9,en;q=0.8" }

    assert_select "html[lang=en][dir=ltr]"
  end

  test "a saved locale cookie overrides the browser header" do
    cookies[:locale] = "en"

    get root_url, headers: { "Accept-Language" => "ar" }

    assert_select "html[lang=en][dir=ltr]"
  end

  test "the toggle saves a locale cookie and redirects back" do
    get locale_url("ar"), headers: { "Referer" => root_url }

    assert_redirected_to root_url
    assert_equal "ar", cookies[:locale]

    follow_redirect!
    assert_select "html[lang=ar][dir=rtl]"
  end

  test "the toggle ignores an unknown locale" do
    get "/locale/zz", headers: { "Referer" => root_url }

    assert_redirected_to root_url
    assert_nil cookies[:locale]
  end

  test "paste subdomains expose no locale toggle route" do
    get "http://#{"a" * 32}.example.com/locale/ar"

    assert_response :not_found
  end
end
