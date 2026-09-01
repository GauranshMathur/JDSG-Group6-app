# One page of a timeline: the rows to render, where the next page is, and what
# the viewer has already done to those rows.
#
# There are four timelines — the feed, a profile, a tag and a search — and until
# finding 4 of the 2026-08-18 review each of them assembled that answer for
# itself. The spread was: `PAGE_SIZE` declared three times under three names,
# three different "is there a next page?" protocols (a lookahead flag and two
# variants of `size == PAGE_SIZE`), two URL dialects (`?page=N` and `?after=`),
# and four views that each knew which of those applied to them. One caller
# forgot the engagement sets entirely, which is why `_post.html.erb` carried a
# `defined?(liked_post_ids)` guard to paper over an interface its callers
# satisfied inconsistently.
#
# Both paging styles survive, because both are right where they are used:
# ADR 0011 chose positional paging for the ranked feed, ADR 0002 keeps keyset
# elsewhere. What was missing was a module that knows which applies where. That
# is the whole of this class: the difference lives in the two constructors, and
# nothing downstream can tell them apart.
class TimelinePage
  PAGE_SIZE = 20

  attr_reader :items, :next_url, :liked_post_ids, :reposted_post_ids

  def initialize(items:, next_url:, viewer:)
    @items = items
    @next_url = next_url
    @liked_post_ids = engaged_ids(viewer&.likes)
    @reposted_post_ids = engaged_ids(viewer&.reposts)
  end

  # The one place a page number is read off a query string, so the one place a
  # bad one is refused. `to_i` is 0 for nil and for "banana"; the floor catches
  # "-1", which used to reach `entries.drop(-20)` and raise — a 500 on the feed
  # and on every profile. No ceiling: a page past the end is a legitimate
  # question with an empty answer.
  def self.page_number(value)
    [ value.to_i, 0 ].max
  end

  # The feed and profiles: a service that already yields FeedItems and knows its
  # own next page number. The block turns that number into this timeline's URL.
  def self.from_feed(feed, viewer:)
    next_page = feed.next_page

    new(items: feed.items,
        next_url: (yield(next_page) if next_page),
        viewer: viewer)
  end

  # Tags and search: a timeline-ordered scope paged by cursor, whose rows are
  # plain posts. They are wrapped as FeedItems so that every timeline hands the
  # views the same thing — a row that may or may not have a reposter.
  #
  # The page is loaded here rather than left to the view because deciding
  # whether there is a next page asks for its size, and on an unloaded relation
  # that is a separate COUNT followed by fetching the rows again.
  def self.from_scope(scope, after:, viewer:)
    cursor = Post.parse_cursor(after)
    scope = scope.older_than(*cursor) if cursor
    posts = scope.limit(PAGE_SIZE).load
    next_cursor = posts.last.cursor if posts.size == PAGE_SIZE

    new(items: posts.map { |post| FeedItem.new(post: post, reposter: nil, sort_time: post.created_at, score: 0) },
        next_url: (yield(next_cursor) if next_cursor),
        viewer: viewer)
  end

  # A page with nothing on it and nowhere to go — what a search with no query
  # renders, and what `posts#create` shows beneath a rejected composer.
  def self.empty(viewer: nil)
    new(items: [], next_url: nil, viewer: viewer)
  end

  def empty?
    items.empty?
  end

  private

  def engaged_ids(association)
    return Set.new if association.nil? || items.empty?

    association.where(post_id: items.map { |item| item.post.id }).pluck(:post_id).to_set
  end
end
