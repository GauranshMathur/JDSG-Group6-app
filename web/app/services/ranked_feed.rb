class RankedFeed
  # Only what happened inside the window competes for the top of the feed —
  # a post by being created, an old post by being reposted. Everything older
  # follows in reverse-chronological order (the archive), so nothing is ever
  # removed from the feed; it merely stops being *ranked*. The window is a
  # cost bound as much as a product choice: rebuild and page cost track the
  # recent write rate instead of the size of the database (ADR 0011).
  WINDOW = 7.days

  # The key changed with the cached value's shape (N-6.8, then F-8.7.1). A
  # process holding the previous whole-timeline ordering must not have it
  # read as a windowed one, and it expires on its own within the TTL.
  CACHE_KEY = "ranked_feed_window"
  # Invalidation marks the ordering stale rather than deleting it, so a reader
  # arriving mid-rebuild has something to serve (F-8.6.1).
  STALE_KEY = "ranked_feed_window:stale"
  # Held by whichever request is rebuilding. Expires on its own so a process
  # that dies mid-rebuild leaves the feed stale for seconds rather than forever.
  REBUILD_LOCK_KEY = "ranked_feed_window:rebuilding"
  REBUILD_LOCK_TTL = 30.seconds
  CACHE_TTL = 5.minutes
  PAGE_SIZE = 20

  def initialize(page: 0)
    @page = page
  end

  def items
    @items ||= hydrate(page_entries)
  end

  def next_page
    page_entries
    @page + 1 if @more
  end

  def self.warm
    Rails.cache.delete(REBUILD_LOCK_KEY)
    new.send(:rebuild_and_store, claimed: false)
  end

  def self.bust_cache
    # Worth a span of its own: every like, repost, reply and post lands here,
    # so the rate of invalidation is what decides how often a reader pays for a
    # rebuild rather than a cache hit (F-8.2).
    #
    # Marking rather than deleting is the whole of F-8.6.1: deleting meant that
    # every reader arriving before the next rebuild finished found nothing and
    # started an identical one.
    tracer.in_span("ranked_feed.bust") do
      Rails.cache.write(STALE_KEY, true, expires_in: CACHE_TTL)
    end
  end

  # Asked for on every call rather than held in config.x: an unset
  # `config.x.anything` returns an auto-vivified OrderedOptions, which is
  # truthy, so a `config.x.tracer || fallback` never reaches its fallback and
  # quietly answers `in_span` with nil instead of yielding. The tracer provider
  # is the right place to ask anyway — it hands back a real tracer when the SDK
  # is configured and a no-op one when it is not.
  def self.tracer
    OpenTelemetry.tracer_provider.tracer("twitter-clone-web")
  end

  private

  def tracer
    self.class.tracer
  end

  # A page is served from the ranked window for as long as the window can fill
  # it, then from the archive. The last page the window reaches asks the
  # archive one bounded question — the rows to fill the shortfall, plus one,
  # which also answers whether the feed continues. Never a COUNT: a count is
  # O(archive), and the archive is the part that grows without bound.
  def page_entries
    @page_entries ||= begin
      entries = ordering[:entries]
      start = @page * PAGE_SIZE

      if entries.size > start + PAGE_SIZE
        @more = true
        entries.drop(start).first(PAGE_SIZE)
      else
        ranked = entries.drop(start).first(PAGE_SIZE)
        shortfall = PAGE_SIZE - ranked.size
        rows = archive.offset([ start - entries.size, 0 ].max)
                      .limit(shortfall + 1)
                      .pluck(:id)
        @more = rows.size > shortfall
        ranked + rows.first(shortfall).map { |id| [ id, nil ] }
      end
    end
  end

  # Everything older than the window, newest first — served straight off the
  # (created_at, id) index, twenty rows at a time. Bounded by the cutoff the
  # ordering was *built* with rather than one computed now, so the archive
  # begins exactly where the cached window ends even when a post crosses the
  # boundary during the cache's lifetime.
  def archive
    Post.top_level.where(created_at: ...ordering[:cutoff])
        .order(created_at: :desc, id: :desc)
  end

  # What is cached is the ranked *order* of the window — the cutoff, and one
  # `[post_id, reposter_id]` pair per entry — and not the posts themselves.
  #
  # The whole-object version of this cached every entry with its author, avatar
  # and images under a single key. Nothing can read part of a cached value, so
  # every request rebuilt all of it in memory before taking twenty: 763 ms at
  # the 10,000-post seed, of which the page slice was 0.0 ms, and growing in
  # step with the database. Identifiers make the read cheap and the page a
  # bounded lookup; the cost of showing twenty posts now tracks twenty posts.
  # Recorded with numbers in docs/stress-testing.md.
  #
  # One rebuild at a time (F-8.6.1). A request rebuilds when there is nothing
  # cached to serve, or when the ordering is stale and no other request has
  # claimed the rebuild. Everyone else serves the previous ordering, which is
  # at most one rebuild out of date — against a ranking that divides engagement
  # by age and so drifts continuously anyway, and a cache that already answers
  # with a value up to CACHE_TTL old whenever nothing is being written.
  def ordering
    @ordering ||= tracer.in_span("ranked_feed.read") do |span|
      cached = Rails.cache.read(CACHE_KEY)
      stale = Rails.cache.read(STALE_KEY).present?
      rebuilt = false

      order =
        if cached.nil?
          rebuilt = true
          rebuild_and_store(claimed: false)
        elsif stale && claim_rebuild
          rebuilt = true
          rebuild_and_store(claimed: true)
        else
          cached
        end

      # cache_hit stays "this request did not rebuild", which is what it has
      # always meant. served_stale is the new state: answered from an ordering
      # that is known to be out of date because someone else is refreshing it.
      span.set_attribute("ranked_feed.cache_hit", !rebuilt)
      span.set_attribute("ranked_feed.served_stale", stale && !rebuilt)
      span.set_attribute("ranked_feed.item_count", order[:entries].size)
      order
    end
  end

  def claim_rebuild
    Rails.cache.write(REBUILD_LOCK_KEY, true, unless_exist: true, expires_in: REBUILD_LOCK_TTL)
  end

  def rebuild_and_store(claimed:)
    order = rebuild
    Rails.cache.write(CACHE_KEY, order, expires_in: CACHE_TTL)
    Rails.cache.delete(STALE_KEY)
    order
  ensure
    Rails.cache.delete(REBUILD_LOCK_KEY) if claimed
  end

  def rebuild
    tracer.in_span("ranked_feed.rebuild") do |span|
      cutoff = WINDOW.ago
      entries = compute_ordering(cutoff)
      span.set_attribute("ranked_feed.item_count", entries.size)
      { cutoff: cutoff, entries: entries }
    end
  end

  # Ranking needs four numbers per entry — likes, reposts, replies and age — so
  # it reads four numbers per entry. Loading each row as a model object, with
  # its author and attachments eager-loaded, was 2,859 ms at the 10,000-post
  # seed against 377 ms for the counters alone, and every one of those objects
  # was discarded after its score was computed.
  #
  # Both reads stop at the cutoff. A repost is dated by the repost, not the
  # post, which is how an old post re-enters the window: someone reposting it
  # is a recent event. Likes on an old post no longer resurface it.
  def compute_ordering(cutoff)
    now = Time.current
    scored = []

    Post.top_level.where(created_at: cutoff..)
        .pluck(:id, :likes_count, :reposts_count, :replies_count, :created_at)
        .each do |id, likes, reposts, replies, created_at|
      scored << [ score(likes, reposts, replies, created_at, now), id, nil ]
    end

    Repost.where(post_id: Post.top_level.select(:id))
          .where(created_at: cutoff..).joins(:post)
          .pluck(:user_id, :post_id, :created_at,
                 "posts.likes_count", "posts.reposts_count", "posts.replies_count")
          .each do |user_id, post_id, reposted_at, likes, reposts, replies|
      scored << [ score(likes, reposts, replies, reposted_at, now), post_id, user_id ]
    end

    scored.sort_by! { |entry| -entry.first }
    scored.map { |_score, post_id, reposter_id| [ post_id, reposter_id ] }
  end

  def score(likes, reposts, replies, at, now)
    age_hours = ((now - at) / 1.hour).clamp(0, Float::INFINITY)
    engagement = likes + (reposts * 2) + replies
    (engagement + 1).to_f / ((age_hours + 2)**1.5)
  end

  # Two queries, whatever the page: the posts it shows, and the accounts that
  # reposted them.
  #
  # An entry naming a row that has since been deleted is dropped rather than
  # rendered — the ordering is a snapshot, and a post can go between the
  # rebuild that recorded it and the request that reads it. Caching whole
  # objects hid this by serving a copy of the deleted post.
  def hydrate(entries)
    return [] if entries.empty?

    posts = Post.where(id: entries.map(&:first))
                .for_rendering
                .index_by(&:id)

    reposter_ids = entries.filter_map(&:last)
    reposters = reposter_ids.any? ? User.where(id: reposter_ids).index_by(&:id) : {}

    entries.filter_map do |post_id, reposter_id|
      post = posts[post_id]
      next if post.nil?

      reposter = reposter_id && reposters[reposter_id]
      next if reposter_id && reposter.nil?

      FeedItem.new(post: post, reposter: reposter)
    end
  end
end
