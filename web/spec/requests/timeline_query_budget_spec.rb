require "rails_helper"

# Tag and search pages render the same post rows as the feed, so they must
# cost the same bounded number of queries. They were the two timelines with
# no budget spec — and the two carrying a 42-query N+1, which is not a
# coincidence: the preload knowledge had no module, so the sites without a
# guard were also the sites without the knowledge. See
# docs/architecture-reviews/2026-08-18.md, finding 1.
RSpec.describe "Timeline query budgets" do
  describe "tag page" do
    it "issues a constant number of queries regardless of the number of posts" do
      create(:post, body: "first post about #ruby")
      one_post = count_queries { get tag_path("ruby") }

      create_list(:post, 19, body: "more about #ruby")
      full_page = count_queries { get tag_path("ruby") }

      expect(one_post).to eq(full_page)
    end
  end

  describe "search page" do
    it "issues a constant number of queries regardless of the number of posts" do
      create(:post, body: "kubernetes at scale")
      one_post = count_queries { get search_path(q: "kubernetes") }

      create_list(:post, 19, body: "kubernetes, again")
      full_page = count_queries { get search_path(q: "kubernetes") }

      expect(one_post).to eq(full_page)
    end
  end
end
