require "rails_helper"

# F-8.7.1, F-8.7.2, F-8.7.3 — the ranking considers a recent window.
#
# Only what happened inside the window competes for the top of the feed; the
# feed then continues into everything older, newest first, so nothing is ever
# removed — an old post merely stops being *ranked*. Search, profiles, tag
# pages and the post's own page never had a window and still do not.
#
# Found by measurement: at the 10k seed the ranking scored all 43,010 entries
# to serve twenty, and none of its top twenty was from the last seven days.
# See ADR 0011.
RSpec.describe "Feed window" do
  describe "the ranking considers only the window (F-8.7.1)" do
    it "does not let an old post outrank the window, however engaged" do
      create_list(:post, RankedFeed::PAGE_SIZE + 1)
      old_popular = create(:post, body: "Old and heavily engaged",
                                  created_at: (RankedFeed::WINDOW + 1.day).ago)
      create_list(:like, 50, post: old_popular)

      get posts_path

      expect(response.body).not_to include("Old and heavily engaged")
    end

    it "lets a repost re-enter an old post into the ranking" do
      # The repost is a recent event even when the post is not, so reposting
      # is the way an old post resurfaces. Likes alone no longer do that.
      create_list(:post, RankedFeed::PAGE_SIZE + 1)
      old_post = create(:post, body: "Old but reposted today",
                               created_at: (RankedFeed::WINDOW + 1.day).ago)
      create_list(:like, 50, post: old_post)
      create(:repost, post: old_post)

      get posts_path

      expect(response.body).to include("Old but reposted today")
      expect(response.body).to include("Reposted by")
    end
  end

  describe "the feed continues into the archive (F-8.7.2)" do
    it "shows older posts after the ranked window, newest first" do
      create(:post, body: "Ancient history", created_at: (RankedFeed::WINDOW + 30.days).ago)
      create(:post, body: "Merely old", created_at: (RankedFeed::WINDOW + 2.days).ago)
      create(:post, body: "Recent enough to rank")

      get posts_path

      body = response.body
      expect(body.index("Recent enough to rank")).to be < body.index("Merely old")
      expect(body.index("Merely old")).to be < body.index("Ancient history")
    end

    it "keeps paginating to the end of the archive" do
      create(:post, body: "The very last post", created_at: (RankedFeed::WINDOW + 90.days).ago)
      RankedFeed::PAGE_SIZE.times do |i|
        create(:post, created_at: (RankedFeed::WINDOW + 1.day + i.hours).ago)
      end
      create(:post, body: "A recent one")

      get posts_path
      expect(response.body).to include("A recent one")
      expect(response.body).to include("Load more")

      get posts_path(page: 1)
      expect(response.body).to include("The very last post")
      expect(response.body).not_to include("Load more")
    end
  end

  describe "old posts are not removed anywhere else (F-8.7.3)" do
    let!(:old_post) do
      create(:post, body: "An old classic about #history",
                    created_at: (RankedFeed::WINDOW + 10.days).ago)
    end

    it "still shows on its author's profile" do
      get profile_path(old_post.user.username)
      expect(response.body).to include("An old classic")
    end

    it "still turns up in search" do
      get search_path(q: "classic")
      expect(response.body).to include("An old classic")
    end

    it "still lives at its own page" do
      get post_path(old_post)
      expect(response.body).to include("An old classic")
    end

    it "still appears on its hashtag page" do
      get tag_path("history")
      expect(response.body).to include("An old classic")
    end
  end
end
