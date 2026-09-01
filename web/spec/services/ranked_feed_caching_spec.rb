require "rails_helper"

# F-6.5.1, F-6.5.2, F-6.5.3
#
# These asserted a warm read cost *zero* queries, which it did: the cache held
# every ranked item as a whole object, so a request needed nothing from the
# database. That was the defect, not the achievement — it made a cache hit
# 763 ms of rebuilding objects in memory at the 10,000-post seed, growing with
# the database (N-6.8, docs/stress-testing.md). What is cached now is the
# ranked order, and a page is a bounded lookup of the posts it displays.
#
# So the budget these hold is "computed once, and a page costs a page" rather
# than zero. The invalidation examples below are unchanged and still the point
# of the file.
RSpec.describe RankedFeed, type: :service do
  # F-6.5.1
  describe "caching" do
    it "computes the ranking once and reuses it" do
      create(:post, body: "cached post")

      RankedFeed.new.items
      ordering = Rails.cache.read(RankedFeed::CACHE_KEY)

      # The posts on the page, and the accounts that reposted them. Never a
      # scan of every post to rank them again.
      expect(count_queries { RankedFeed.new.items }).to be <= 2
      expect(Rails.cache.read(RankedFeed::CACHE_KEY)).to eq(ordering)
    end

    it "paginates from the cached ordering" do
      create_list(:post, RankedFeed::PAGE_SIZE + 5)

      RankedFeed.new.items

      queries = count_queries do
        page2 = RankedFeed.new(page: 1).items
        expect(page2.size).to eq(5)
      end

      expect(queries).to be <= 2
    end
  end

  # F-6.5.2
  describe "cache invalidation" do
    it "invalidates when a new post is created" do
      post = create(:post, body: "original")
      items = RankedFeed.new.items
      expect(items.map { |i| i.post.body }).to include("original")

      create(:post, body: "brand new")
      items = RankedFeed.new.items
      expect(items.map { |i| i.post.body }).to include("brand new")
    end

    it "invalidates when a post is destroyed" do
      post = create(:post, body: "doomed")
      RankedFeed.new.items

      post.destroy!
      items = RankedFeed.new.items
      expect(items.map { |i| i.post.body }).not_to include("doomed")
    end

    it "invalidates when a like is created" do
      post = create(:post, body: "likeable")
      RankedFeed.new.items

      create(:like, post: post)
      items = RankedFeed.new.items
      liked = items.find { |i| i.post.body == "likeable" }
      expect(liked.post.likes_count).to eq(1)
    end

    it "invalidates when a like is destroyed" do
      post = create(:post, body: "unliked")
      like = create(:like, post: post)
      RankedFeed.new.items

      like.destroy!
      items = RankedFeed.new.items
      found = items.find { |i| i.post.body == "unliked" }
      expect(found.post.likes_count).to eq(0)
    end

    it "invalidates when a repost is created" do
      post = create(:post, body: "repostable")
      RankedFeed.new.items

      repost = create(:repost, post: post)
      items = RankedFeed.new.items
      expect(items.any? { |i| i.repost? && i.post.body == "repostable" }).to be true
    end

    it "invalidates when a repost is destroyed" do
      post = create(:post, body: "unreposted")
      repost = create(:repost, post: post)
      RankedFeed.new.items

      repost.destroy!
      items = RankedFeed.new.items
      expect(items.none? { |i| i.repost? && i.post.body == "unreposted" }).to be true
    end
  end

  # F-6.5.3
  describe "warm on boot" do
    it "populates the ordering via RankedFeed.warm, so the first request does not rebuild" do
      create(:post, body: "warmed post")

      Rails.cache.clear
      RankedFeed.warm

      expect(Rails.cache.read(RankedFeed::CACHE_KEY)).to be_present

      queries = count_queries do
        items = RankedFeed.new.items
        expect(items.map { |i| i.post.body }).to include("warmed post")
      end

      expect(queries).to be <= 2
    end
  end
end
