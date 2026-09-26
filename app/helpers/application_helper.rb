module ApplicationHelper
  # Rails' default safe list has no tables, which agents use for test results.
  MARKDOWN_TAGS = (Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + %w[table thead tbody tr th td]).freeze

  # Sessions write their report_idle summaries as Markdown, and the run screen
  # shows those checkpoints instead of the pane. Commonmarker already refuses
  # raw HTML and unsafe link schemes by default; sanitize is belt and braces,
  # since the text is written by an agent with full access to a worktree.
  # Hard breaks because agents write line-per-thought prose and expect it to
  # render the way it reads in the terminal.
  def render_markdown(text)
    return "" if text.blank?

    html = Commonmarker.to_html(
      text.to_s,
      options: { extension: { header_ids: nil }, render: { hardbreaks: true } }
    )
    sanitize(html, tags: MARKDOWN_TAGS)
  end
end
