require "rails_helper"

# N-6.8 — serving a page of the feed costs work proportional to the page, not
# to the number of posts in the database.
#
# The feed used to cache every ranked item as a whole object under one key.
# Nothing could read part of that value, so every request — including page 51 —
# rebuilt all of it in memory to display twenty posts, and the cost grew with
# the database: measured at 71.9 ms for 4,083 items and 763 ms for 43,058, with
# the page slice itself at 0.0 ms. See docs/stress-testing.md.
#
# What is cached now is the ordering — identifiers in ranked order — and the
# posts on the page being displayed are loaded from the database. These specs
# hold that shape in place, because the old one also looked correct and passed
# every functional spec while being the reason the app fell over at three
# requests a second.
RSpec.describe RankedFeed, type: :service do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  def records_instantiated_in
    counts = Hash.new(0)
    callback = ->(_name, _start, _finish, _id, payload) do
      counts[payload[:class_name]] += payload[:record_count].to_i
    end
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { yield }
    counts
  end

  describe "what the cache holds" do
    it "caches an ordering of identifiers rather than the posts themselves" do
      create_list(:post, 3)
      RankedFeed.new.items

      cached = Rails.cache.read(RankedFeed::CACHE_KEY)

      expect(cached.flatten.compact).to all(be_a(Integer))
    end

    it "keeps the cached payload proportional to the number of entries, not their contents" do
      create_list(:post, 50)
      RankedFeed.new.items

      bytes = Marshal.dump(Rails.cache.read(RankedFeed::CACHE_KEY)).bytesize

      # Tens of bytes an entry, not the kilobytes a post with its author,
      # avatar and images costs.
      expect(bytes).to be < 50 * 100
    end
  end

  describe "what a request pays" do
    it "instantiates a page of posts rather than the whole feed" do
      create_list(:post, RankedFeed::PAGE_SIZE * 3)
      RankedFeed.new.items

      counts = records_instantiated_in { RankedFeed.new.items }

      expect(counts["Post"]).to be <= RankedFeed::PAGE_SIZE
    end

    it "costs the same for a later page as for the first" do
      create_list(:post, RankedFeed::PAGE_SIZE * 3)
      RankedFeed.new.items

      first = count_queries { RankedFeed.new(page: 0).items }
      later = count_queries { RankedFeed.new(page: 2).items }

      expect(later).to eq(first)
    end

    it "issues the same number of queries for a large feed as for a small one" do
      create_list(:post, RankedFeed::PAGE_SIZE + 5)
      RankedFeed.new.items
      small = count_queries { RankedFeed.new.items }

      create_list(:post, RankedFeed::PAGE_SIZE * 4)
      RankedFeed.new.items
      large = count_queries { RankedFeed.new.items }

      expect(large).to eq(small)
    end
  end

  describe "an ordering that has gone stale" do
    # `delete` skips the callbacks, so the cached ordering still names a post
    # that no longer exists — which is also what a race between a rebuild and a
    # deletion produces. Caching whole objects hid this; caching identifiers
    # means the row has to be looked up, so it has to be handled.
    it "skips a post deleted since the ordering was cached" do
      posts = create_list(:post, 3)
      RankedFeed.new.items

      posts.first.delete

      items = RankedFeed.new.items
      expect(items.map { |item| item.post.id }).not_to include(posts.first.id)
      expect(items.size).to eq(2)
    end

    it "skips a repost whose reposter is gone" do
      post = create(:post)
      repost = create(:repost, post: post)
      RankedFeed.new.items

      reposter_id = repost.user_id
      repost.delete
      User.where(id: reposter_id).delete_all

      items = RankedFeed.new.items
      expect(items.none? { |item| item.repost? }).to be true
    end
  end
end
