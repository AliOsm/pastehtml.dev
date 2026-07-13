require "test_helper"

class MarkdownDocumentTest < ActiveSupport::TestCase
  test "renders github-flavored markdown into the branded page" do
    html = MarkdownDocument.new(<<~MD, filename: "doc.md").to_html
      # Heading

      Text with **bold**, ~~strike~~, and a [link](https://example.com).

      | a | b |
      |---|---|
      | 1 | 2 |

      - [ ] todo
      - [x] done
    MD

    assert_includes html, "<!DOCTYPE html>"
    assert_includes html, 'class="md-body"'
    assert_includes html, ">Heading</h1>"
    assert_includes html, "<strong>bold</strong>"
    assert_includes html, "<del>strike</del>"
    assert_includes html, "<th>a</th>"
    assert_includes html, 'type="checkbox"'
  end

  test "titles the page from the first h1, else the filename" do
    assert_includes MarkdownDocument.new("# Real Title\n\nbody", filename: "x.md").to_html,
      "<title>Real Title</title>"
    assert_includes MarkdownDocument.new("just body, no heading", filename: "my-notes.md").to_html,
      "<title>my-notes</title>"
  end

  test "highlights code fences with rouge, not a runtime fetch" do
    html = MarkdownDocument.new("```ruby\ndef hi; end\n```", filename: "x.md").to_html

    assert_includes html, 'class="highlight"'
    assert_includes html, "<span"
    assert_not_includes html, "highlight.js"
  end

  test "renders mermaid fences as diagram containers and injects the pinned module only when present" do
    with_diagram = MarkdownDocument.new("```mermaid\ngraph TD; A-->B;\n```", filename: "x.md").to_html
    assert_includes with_diagram, '<pre class="mermaid">'
    assert_includes with_diagram, "graph TD; A--&gt;B;"
    assert_includes with_diagram, "mermaid@11.4.1"
    assert_not_includes with_diagram, "<span" # the diagram source is left untokenized

    without_diagram = MarkdownDocument.new("# Plain\n\ntext", filename: "x.md").to_html
    assert_not_includes without_diagram, "mermaid@" # no CDN module when there's no diagram
    assert_not_includes without_diagram, "<script"
  end

  test "drops raw html embedded in the markdown" do
    html = MarkdownDocument.new("ok\n\n<script>alert('xss')</script>", filename: "x.md").to_html

    assert_not_includes html, "alert('xss')"
  end

  test "strips yaml front matter and uses it for title and description" do
    html = MarkdownDocument.new(<<~MD, filename: "x.md").to_html
      ---
      title: "My Document Title"
      author: "Jane Doe"
      date: 2026-07-13
      tags: [markdown, tutorial, yaml]
      draft: false
      description: "A test document"
      ---

      # Document Heading Starts Here
      This is the regular Markdown body text.
    MD

    assert_includes html, "<title>My Document Title</title>"
    assert_includes html, '<meta name="description" content="A test document">'
    assert_not_includes html, "title: \"My Document Title\""
    assert_includes html, ">Document Heading Starts Here</h1>"
  end

  test "front matter title overrides an h1" do
    html = MarkdownDocument.new(<<~MD, filename: "x.md").to_html
      ---
      title: From Front Matter
      ---
      # From Heading
    MD

    assert_includes html, "<title>From Front Matter</title>"
  end

  test "falls back to h1, then filename, when front matter has no title" do
    assert_includes MarkdownDocument.new("---\nauthor: Jane\n---\n# Heading", filename: "x.md").to_html,
      "<title>Heading</title>"
    assert_includes MarkdownDocument.new("---\nauthor: Jane\n---\nbody", filename: "my-notes.md").to_html,
      "<title>my-notes</title>"
  end

  test "omits the description tag when front matter has none" do
    html = MarkdownDocument.new("# Plain\n\ntext", filename: "x.md").to_html
    assert_not_includes html, 'name="description"'
  end

  test "treats malformed or non-mapping front matter as plain body" do
    malformed = MarkdownDocument.new("---\n[1, 2\n---\nbody", filename: "x.md").to_html
    assert_includes malformed, "[1, 2"

    sequence = MarkdownDocument.new("---\n- a\n- b\n---\nbody", filename: "x.md").to_html
    assert_includes sequence, "<li>a</li>"
    assert_includes sequence, "<li>b</li>"
  end

  test "does not treat a body horizontal rule as front matter" do
    html = MarkdownDocument.new("no leading marker\n\n---\n\nafter the rule", filename: "x.md").to_html
    assert_includes html, "<hr"
  end
end
