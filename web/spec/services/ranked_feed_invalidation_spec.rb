require "rails_helper"

# Finding 6 of the 2026-08-18 architecture review: the write side busts the
# ordering for events the read side is defined to ignore.
#
# What the ranking actually reads is two sets — top-level posts created inside
# the window, and reposts made inside the window — scored from the post's like,
# repost and reply counters. A write matters only if it changes membership of
# one of those sets, or a counter on a post already in one. Anything else forces
# a rebuild that produces a byte-identical result.
#
# These specs assert the decision rather than the cache, because the test
# environment's cache is :null_store and cannot observe a bust. That is finding
# 3, still open.
RSpec.describe "Ranked feed invalidation" do
  let(:cutoff) { RankedFeed::WINDOW.ago }
  let(:ranked) { create(:post, created_at: 1.hour.ago) }
  let(:archived) { create(:post, created_at: (RankedFeed::WINDOW + 2.days).ago) }

  describe "events the ranking reads" do
    it "busts when a top-level post is created — it joins the window" do
      expect(RankedFeed).to receive(:bust_cache)

      create(:post)
    end

    it "busts when a ranked post is liked — its like counter is a score input" do
      ranked
      expect(RankedFeed).to receive(:bust_cache)

      create(:like, post: ranked)
    end

    it "busts when a ranked post is replied to — its reply counter is a score input" do
      ranked
      expect(RankedFeed).to receive(:bust_cache)

      create(:post, parent: ranked)
    end

    it "busts when an archived post is reposted — reposting is how an old post re-enters" do
      archived
      expect(RankedFeed).to receive(:bust_cache)

      create(:repost, post: archived)
    end

    it "busts when an archived post that was recently reposted is liked" do
      create(:repost, post: archived, created_at: 1.hour.ago)
      expect(RankedFeed).to receive(:bust_cache)

      create(:like, post: archived)
    end
  end

  describe "events the ranking cannot see" do
    it "does not bust when an archived post is liked" do
      archived
      expect(RankedFeed).not_to receive(:bust_cache)

      create(:like, post: archived)
    end

    it "does not bust when an archived post is replied to" do
      archived
      expect(RankedFeed).not_to receive(:bust_cache)

      create(:post, parent: archived)
    end

    it "does not bust when a like on an archived post is withdrawn" do
      like = create(:like, post: archived)
      expect(RankedFeed).not_to receive(:bust_cache)

      like.destroy!
    end
  end

  # The review also flagged the absent after_update_commit. It is absent on
  # purpose now: what is cached is the ordering — [post_id, reposter_id] pairs —
  # and posts are re-read on every request, so an edit is visible without any
  # invalidation. An edit changes no score input either. The second example is
  # the one that would fail if that reasoning were wrong.
  describe "editing a post", type: :request do
    it "does not bust the ordering, because no score input changed" do
      post = ranked
      expect(RankedFeed).not_to receive(:bust_cache)

      post.update!(body: "rewritten")
    end

    it "still shows the new body on the feed, cached ordering or not" do
      post = create(:post, body: "before the edit")
      get posts_path
      post.update!(body: "after the edit")

      get posts_path

      expect(response.body).to include("after the edit")
      expect(response.body).not_to include("before the edit")
    end
  end
end
