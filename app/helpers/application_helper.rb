module ApplicationHelper
  def default_meta_tags
    {
      site: "pastehtml.dev",
      reverse: true,
      separator: "—",
      description: t("home.meta_description"),
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

  # A single comic button, matching the header nav buttons, that flips to the
  # other language -- labelled with that language's own name (عربي on the English
  # UI, EN on the Arabic one). Straight on mobile, tilted from sm up like its
  # neighbours; its lang/dir make the label's script shape correctly.
  def locale_toggle
    other = I18n.available_locales.find { |locale| locale != I18n.locale } || I18n.locale
    link_to t("language_short", locale: other), locale_path(other),
      lang: other, dir: dir_for(other), aria: { label: t("layout.switch_language") },
      class: "inline-flex size-11 items-center justify-center border-2 border-ink bg-white font-display text-xs tracking-wide text-ink shadow-comic-sm hover:bg-hero-yellow sm:size-auto sm:rotate-1 sm:px-2.5 sm:py-1 sm:text-sm"
  end

  def text_direction
    dir_for(I18n.locale)
  end

  # Header nav-item icons, shown only on mobile (sm:hidden) where the text label
  # is hidden to keep the header on a single, uncrowded row. Paths are Heroicons
  # (outline) constants -- no user input -- so the built string is safe to mark.
  NAV_ICON_PATHS = {
    dashboard: "M3.75 6A2.25 2.25 0 0 1 6 3.75h2.25A2.25 2.25 0 0 1 10.5 6v2.25a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25V6ZM3.75 15.75A2.25 2.25 0 0 1 6 13.5h2.25a2.25 2.25 0 0 1 2.25 2.25V18a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18v-2.25ZM13.5 6a2.25 2.25 0 0 1 2.25-2.25H18A2.25 2.25 0 0 1 20.25 6v2.25A2.25 2.25 0 0 1 18 10.5h-2.25a2.25 2.25 0 0 1-2.25-2.25V6ZM13.5 15.75a2.25 2.25 0 0 1 2.25-2.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-2.25a2.25 2.25 0 0 1-2.25-2.25v-2.25Z",
    api_keys: "M15.75 5.25a3 3 0 0 1 3 3m3 0a6 6 0 0 1-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1 1 21.75 8.25Z",
    sign_out: "M8.25 9V5.25A2.25 2.25 0 0 1 10.5 3h6a2.25 2.25 0 0 1 2.25 2.25v13.5A2.25 2.25 0 0 1 16.5 21h-6a2.25 2.25 0 0 1-2.25-2.25V15m-3 0-3-3m0 0 3-3m-3 3H15",
    sign_in: "M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15m3 0 3-3m0 0-3-3m3 3H9",
    sign_up: "M19 7.5v3m0 0v3m0-3h3m-3 0h-3m-2.25-4.125a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0ZM4 19.235v-.11a6.375 6.375 0 0 1 12.75 0v.109A12.318 12.318 0 0 1 10.374 21c-2.331 0-4.512-.645-6.374-1.766Z"
  }.freeze

  def nav_icon(name)
    %(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="size-5 sm:hidden" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" d="#{NAV_ICON_PATHS[name]}" /></svg>).html_safe
  end

  # Which top-level header nav item, if any, the current page belongs to. Keyed
  # on controller/action (not current_page?) so folder pages count as the
  # dashboard and a failed sign-in/up keeps its own form highlighted despite the
  # ?email_address= query the redirect carries.
  def current_nav?(section)
    case section
    when :dashboard then controller_name == "folders" || (controller_name == "pastes" && action_name == "index")
    when :api_keys  then controller_name == "api_keys"
    when :sign_in   then controller_name == "sessions" && action_name == "new"
    when :sign_up   then controller_name == "users" && action_name == "new"
    else false
    end
  end

  private
    def dir_for(locale)
      locale.to_sym == :ar ? "rtl" : "ltr"
    end
end
