require "rails_helper"

# F-8.6.1 — one rebuild at a time. A reader arriving while the ordering is
# being rebuilt serves the previous one instead of recomputing it.
#
# Invalidation used to delete the ordering outright, so the moment anyone liked
# a post every reader arriving in the next 643 ms found nothing cached and each
# started an identical rebuild — three workers doing one job while everyone
# else queued behind them. Invisible while a cache hit cost 763 ms and a
# rebuild 2,859 ms; the dominant remaining cost once a hit became 16 ms
# (N-6.8). Measured in docs/stress-testing.md.
#
# The trade is that a reader can see an ordering one rebuild out of date. The
# ranking divides engagement by age, so it drifts continuously anyway, and the
# cache already answers with a value up to CACHE_TTL old whenever nothing is
# being written.
RSpec.describe RankedFeed, type: :service do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  def cached_ordering
    Rails.cache.read(RankedFeed::CACHE_KEY)&.[](:entries)
  end

  it "keeps the previous ordering available when the feed is invalidated" do
    create(:post)
    RankedFeed.new.items

    RankedFeed.bust_cache

    expect(cached_ordering).to be_present
  end

  it "serves the previous ordering while another request holds the rebuild" do
    create_list(:post, 3)
    RankedFeed.new.items
    expect(cached_ordering.size).to eq(3)

    create(:post)

    # Stand in for a request that is already rebuilding.
    Rails.cache.write(RankedFeed::REBUILD_LOCK_KEY, true, expires_in: 30.seconds)

    items = RankedFeed.new.items

    expect(items.size).to eq(3)
    expect(cached_ordering.size).to eq(3)
  end

  it "rebuilds once the request holding it is finished" do
    create_list(:post, 3)
    RankedFeed.new.items
    create(:post)
    Rails.cache.write(RankedFeed::REBUILD_LOCK_KEY, true, expires_in: 30.seconds)
    RankedFeed.new.items

    Rails.cache.delete(RankedFeed::REBUILD_LOCK_KEY)

    expect(RankedFeed.new.items.size).to eq(4)
    expect(cached_ordering.size).to eq(4)
  end

  it "does not hold the rebuild once it is done, so the next invalidation rebuilds" do
    create(:post)
    RankedFeed.new.items

    expect(Rails.cache.read(RankedFeed::REBUILD_LOCK_KEY)).to be_nil
  end

  it "still rebuilds synchronously when there is no ordering to serve" do
    create_list(:post, 2)

    expect(RankedFeed.new.items.size).to eq(2)
  end
end
