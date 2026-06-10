module PastesHelper
  # Highlighting a 2 MB paste costs ~1.5s of CPU; beyond this we fall back to
  # escaped plain text (the fragment cache covers repeat views either way).
  HIGHLIGHT_LIMIT = 256.kilobytes

  # Rouge tokenizes and escapes every character of the paste, so the
  # generated markup contains only its own spans around escaped text.
  def highlighted_source(content)
    return ERB::Util.html_escape(content) if content.bytesize > HIGHLIGHT_LIMIT

    Rouge::Formatters::HTML.new.format(Rouge::Lexers::HTML.new.lex(content)).html_safe
  end
end
