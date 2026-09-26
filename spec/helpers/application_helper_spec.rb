require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#render_markdown" do
    it "renders GitHub-flavoured Markdown" do
      html = helper.render_markdown("## What changed\n\n- one\n- `two`\n\n| a | b |\n|---|---|\n| 1 | 2 |")

      expect(html).to include("<h2>What changed</h2>")
      expect(html).to include("<li><code>two</code></li>")
      expect(html).to include("<table>")
    end

    it "keeps single line breaks the way the agent wrote them" do
      expect(helper.render_markdown("first\nsecond")).to include("first<br>")
    end

    # The summary comes from an agent with full access to a worktree; nothing
    # it writes may execute on the operator's run screen.
    it "drops raw HTML and script links" do
      html = helper.render_markdown("<script>alert(1)</script>\n\n[click](javascript:alert(1))")

      expect(html).not_to include("<script")
      expect(html).not_to include("javascript:")
    end

    it "renders nothing for a blank summary" do
      expect(helper.render_markdown(nil)).to eq("")
    end
  end
end
