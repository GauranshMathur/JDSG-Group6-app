require "rails_helper"

# F-8.7.1, F-8.7.2 — what the window means for the cache and the page.
#
# The cached ordering holds only entries from inside the window, together with
# the cutoff that bounded them, so rebuild and page cost track the recent
# write rate rather than the size of the database. Pages that run past the
# window are filled from the archive — older posts, newest first — with one
# bounded query, never a count.
RSpec.describe RankedFeed, type: :service do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe "what the window caches (F-8.7.1)" do
    it "caches only entries from inside the window, with the cutoff that bounds them" do
      recent = create(:post)
      create(:post, created_at: (RankedFeed::WINDOW + 1.day).ago)

      RankedFeed.new.items
      cached = Rails.cache.read(RankedFeed::CACHE_KEY)

      expect(cached[:entries].map(&:first)).to eq([ recent.id ])
      expect(cached[:cutoff]).to be_within(1.minute).of(RankedFeed::WINDOW.ago)
    end

    it "ranks a recent repost of an old post inside the window" do
      old_post = create(:post, created_at: (RankedFeed::WINDOW + 1.day).ago)
      repost = create(:repost, post: old_post)

      RankedFeed.new.items
      cached = Rails.cache.read(RankedFeed::CACHE_KEY)

      expect(cached[:entries]).to include([ old_post.id, repost.user_id ])
    end
  end

  describe "how a page crosses into the archive (F-8.7.2)" do
    it "fills the page across the boundary, ranked first then the archive" do
      old = 5.times.map do |i|
        create(:post, created_at: (RankedFeed::WINDOW + 1.day + i.hours).ago)
      end
      recent = create_list(:post, 3)

      items = RankedFeed.new.items

      expect(items.size).to eq(8)
      expect(items.first(3).map { |i| i.post.id }).to match_array(recent.map(&:id))
      expect(items.drop(3).map { |i| i.post.id }).to eq(old.map(&:id))
    end

    it "never asks the archive for a count" do
      create_list(:post, 3)
      create(:post, created_at: (RankedFeed::WINDOW + 1.day).ago)

      sql = queries_in do
        feed = RankedFeed.new
        feed.items
        feed.next_page
      end

      expect(sql.grep(/\bCOUNT\s*\(/i)).to be_empty
    end

    it "ends the timeline when the archive is exhausted" do
      create(:post)
      create(:post, created_at: (RankedFeed::WINDOW + 1.day).ago)

      feed = RankedFeed.new(page: 3)

      expect(feed.items).to be_empty
      expect(feed.next_page).to be_nil
    end
  end
end
