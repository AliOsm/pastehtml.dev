module ApplicationHelper
  DEFAULT_DESCRIPTION = "Drop an HTML file, get a private link to share. No sign-up, no editing, no fuss."

  def default_meta_tags
    {
      site: "pastehtml.dev",
      reverse: true,
      separator: "—",
      description: DEFAULT_DESCRIPTION,
      canonical: request.original_url,
      og: {
        title: :title,
        description: :description,
        site_name: :site,
        type: "website",
        url: request.original_url,
        image: og_image_url
      },
      twitter: {
        card: "summary_large_image",
        image: og_image_url
      }
    }
  end

  def og_image_url
    "#{request.base_url}/og-image.png"
  end
end
