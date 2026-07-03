# Renders GitHub-flavored Markdown into a self-contained HTML page dressed in
# the pastehtml.dev brand -- the server-side counterpart to the client-side
# mark-it-down guide. Because we render here (not in the browser), the stored
# paste is real HTML: /raw, /render, the live origin, /markdown read-back, the
# source view, and <title> extraction all keep working unchanged.
#
# Code fences are highlighted with Rouge (the same highlighter the source view
# uses) so nothing is fetched at view time. Mermaid is the exception: its
# library is ~2.8 MB -- far past the 2 MB paste limit -- so it can never be
# inlined. Mermaid fences are left as <pre class="mermaid"> and upgraded in the
# browser by a pinned CDN module, injected ONLY when the document actually
# contains a diagram.
class MarkdownDocument
  # GitHub's flavor: tables, ~~strikethrough~~, the raw-HTML tag filter,
  # autolinks, task lists, and footnotes.
  EXTENSIONS = {
    table: true, strikethrough: true, tagfilter: true,
    autolink: true, tasklist: true, footnotes: true
  }.freeze

  # Pinned so a stored paste renders identically forever. The ESM build boots
  # itself via startOnLoad and upgrades every <pre class="mermaid">.
  MERMAID_MODULE = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs".freeze

  # The brand fonts the .md-body styles reference (Bangers for headings, Inter
  # for body, IBM Plex Mono for code, Lalezar/IBM Plex Sans Arabic for RTL).
  FONTS_HREF = "https://fonts.googleapis.com/css2?family=Bangers&family=Inter:wght@400;600;700&family=IBM+Plex+Mono:wght@400;500&family=Lalezar&family=IBM+Plex+Sans+Arabic:wght@400;600;700&display=swap".freeze

  FORMATTER = Rouge::Formatters::HTML.new

  # github.dark tokens read cleanly on the brand's ink code background; the
  # classed spans Rouge emits pair with this stylesheet, rendered once at boot.
  HIGHLIGHT_CSS = Rouge::Theme.find("github.dark").render(scope: ".md-body .highlight").freeze

  # The brand chrome, lifted verbatim from the mark-it-down template so a
  # server-rendered page is visually identical to one built by the guide.
  BRAND_CSS = <<~CSS.freeze
    :root { --ink:#18120e; --paper:#fff8ec; --red:#e62429; --yellow:#ffd400; --blue:#0072ce; }
    * { margin:0; box-sizing:border-box; }
    body { background-color:var(--paper);
      background-image:radial-gradient(circle, rgb(24 18 14 / 0.07) 1px, transparent 1.4px);
      background-size:12px 12px; color:var(--ink);
      font-family:Inter,"IBM Plex Sans Arabic",system-ui,sans-serif; -webkit-font-smoothing:antialiased; }
    [dir="rtl"] * { letter-spacing:normal; }
    .md-body { max-width: 50rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; color: var(--ink); line-height: 1.65; }
    .md-body > :first-child { margin-top: 0; }
    .md-body h1, .md-body h2, .md-body h3, .md-body h4 { font-family: Bangers, Lalezar, Impact, sans-serif; letter-spacing: 0.02em; line-height: 1.2; margin: 1.8rem 0 0.7rem; }
    .md-body h1 { font-size: clamp(2.2rem,6vw,3rem); text-shadow: 2px 2px 0 var(--red); }
    .md-body h2 { font-size: 1.8rem; border-bottom: 3px solid var(--ink); padding-bottom: 0.2rem; }
    .md-body h3 { font-size: 1.4rem; } .md-body h4 { font-size: 1.15rem; }
    .md-body p { margin: 0.85rem 0; }
    .md-body a { color: var(--blue); text-decoration: underline; text-underline-offset: 2px; }
    .md-body ul, .md-body ol { margin: 0.85rem 0; padding-inline-start: 1.7rem; }
    .md-body li { margin: 0.3rem 0; }
    .md-body code { font-family: "IBM Plex Mono", "IBM Plex Sans Arabic", monospace; font-size: 0.85em; background: rgb(24 18 14 / 0.08); border-radius: 4px; padding: 0.08rem 0.34rem; unicode-bidi: isolate; }
    .md-body pre { direction: ltr; text-align: left; background: var(--ink); border: 3px solid var(--ink); border-radius: 12px; box-shadow: 5px 5px 0 0 var(--red); padding: 1rem 1.1rem; overflow-x: auto; margin: 1.1rem 0; }
    .md-body pre code { background: none; padding: 0; font-size: 0.85rem; line-height: 1.55; }
    .md-body blockquote { border-inline-start: 6px solid var(--yellow); background: #fff7d6; margin: 1.1rem 0; padding: 0.6rem 1rem; border-radius: 8px; border-start-start-radius: 0; border-end-start-radius: 0; }
    .md-body blockquote > :first-child { margin-top: 0; } .md-body blockquote > :last-child { margin-bottom: 0; }
    .md-body table { border-collapse: collapse; margin: 1.1rem 0; width: 100%; display: block; overflow-x: auto; }
    .md-body th, .md-body td { border: 2px solid var(--ink); padding: 0.45rem 0.7rem; text-align: start; }
    .md-body th { background: var(--yellow); font-family: "IBM Plex Mono", "IBM Plex Sans Arabic", monospace; font-size: 0.9rem; }
    .md-body img { max-width: 100%; height: auto; border: 3px solid var(--ink); border-radius: 8px; }
    .md-body hr { border: none; border-top: 3px dashed rgb(24 18 14 / 0.3); margin: 1.8rem 0; }
    .md-body input[type="checkbox"] { width: 1rem; height: 1rem; vertical-align: middle; margin-inline-end: 0.3rem; }
    .md-body pre.mermaid { background: none; border: none; box-shadow: none; padding: 0; text-align: center; }
  CSS

  def initialize(markdown, filename: nil)
    @markdown = markdown.to_s
    @filename = filename.to_s
  end

  # The full HTML document. Safe to store and serve verbatim as a paste.
  def to_html
    body = render_body
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{CGI.escapeHTML(document_title)}</title>
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link rel="stylesheet" href="#{FONTS_HREF}">
      <style>
      #{BRAND_CSS}#{HIGHLIGHT_CSS}
      .md-body pre code.highlight { background: transparent; padding: 0; }
      </style>
      </head>
      <body>
      <main class="md-body" dir="auto">
      #{body}
      </main>
      #{mermaid_script}
      </body>
      </html>
    HTML
  end

  private
    # Convert the Markdown, then post-process every code fence: Mermaid fences
    # become diagram containers, all others are highlighted with Rouge. Raw HTML
    # in the source is dropped (unsafe: false) -- the plain HTML upload path
    # already exists for anyone who wants arbitrary markup.
    def render_body
      html = Commonmarker.to_html(@markdown,
        options: { extension: EXTENSIONS, render: { unsafe: false } },
        plugins: { syntax_highlighter: nil })

      fragment = Nokogiri::HTML5.fragment(html)
      fragment.css("pre").each { |pre| transform_code_block(pre) }
      @heading = fragment.at_css("h1")&.text&.strip
      fragment.to_html
    end

    def transform_code_block(pre)
      code = pre.at_css("code")
      return unless code

      language = pre["lang"].to_s
      source = code.text
      pre.remove_attribute("lang")

      if language == "mermaid"
        @has_mermaid = true
        pre["class"] = "mermaid"
        pre.content = source # replaces <code>; Mermaid reads the element's text
      else
        lexer = Rouge::Lexer.find(language) || Rouge::Lexers::PlainText
        code["class"] = "highlight"
        code.inner_html = FORMATTER.format(lexer.lex(source))
      end
    end

    def mermaid_script
      return "" unless @has_mermaid

      %(<script type="module">) +
        %(import mermaid from "#{MERMAID_MODULE}";mermaid.initialize({ startOnLoad: true });) +
        %(</script>)
    end

    # The document's own H1 names it; fall back to the filename (sans extension)
    # so the paste still gets a meaningful <title> -- and title.
    def document_title
      @heading.presence || File.basename(@filename, ".*").presence || "Untitled"
    end
end
