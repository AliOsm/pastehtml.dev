require "test_helper"

class SitemapTest < ActionDispatch::IntegrationTest
  # The canonical, indexable pages -- exactly the views that set_meta_tags
  # WITHOUT noindex: everything else (pastes, dashboard, auth) is noindex.
  SITEMAP_PATHS = %w[ / /making-of /lock-it-up /mark-it-down ].freeze

  test "sitemap.xml lists exactly the public pages on the canonical apex host" do
    get "/sitemap.xml"

    assert_response :success
    assert_includes response.body, %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)

    locs = response.body.scan(%r{<loc>(.+?)</loc>}).flatten
    assert_equal SITEMAP_PATHS.map { |path| "https://pastehtml.dev#{path}" }, locs
  end

  test "robots.txt advertises the sitemap" do
    get "/robots.txt"

    assert_response :success
    assert_includes response.body, "Sitemap: https://pastehtml.dev/sitemap.xml"
  end

  # Guards the static sitemap against drift: every listed page must still resolve
  # and must not be noindex, so a renamed route or a page turning private fails here.
  test "every page in the sitemap resolves and is indexable" do
    SITEMAP_PATHS.each do |path|
      get path
      assert_response :success, "#{path} is in the sitemap but did not resolve"
      assert_select "meta[name=robots][content*=noindex]", false,
        "#{path} is in the sitemap but is marked noindex"
    end
  end
end
