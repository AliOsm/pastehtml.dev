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

  # The comic header chip that flips the UI between English and Arabic. Forced
  # LTR so the two segments keep a stable "EN | عربي" order in both directions;
  # each label carries its own lang/dir so its script always shapes correctly.
  def locale_toggle
    tag.nav dir: "ltr", aria: { label: t("layout.switch_language") },
        class: "inline-flex rotate-1 items-center overflow-hidden rounded-md border-2 border-ink bg-white font-display text-base tracking-wide shadow-comic-sm" do
      safe_join(I18n.available_locales.map.with_index { |locale, i| locale_segment(locale, first: i.zero?) })
    end
  end

  def text_direction
    dir_for(I18n.locale)
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
    def locale_segment(locale, first:)
      label = t("language_short", locale: locale)
      divider = first ? "" : " border-s-2 border-ink"

      if locale == I18n.locale
        tag.span label, lang: locale, dir: dir_for(locale), aria: { current: "true" },
          class: "bg-ink px-2.5 py-0.5 text-paper#{divider}"
      else
        link_to label, locale_path(locale), lang: locale, dir: dir_for(locale),
          class: "px-2.5 py-0.5 text-ink/60 hover:bg-hero-yellow hover:text-ink#{divider}"
      end
    end

    def dir_for(locale)
      locale.to_sym == :ar ? "rtl" : "ltr"
    end
end
