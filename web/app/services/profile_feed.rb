class ProfileFeed
  PAGE_SIZE = 20

  def initialize(user, page: 0)
    @user = user
    @page = page
  end

  def items
    @items ||= hydrate(page_entries)
  end

  def next_page
    page_entries
    @page + 1 if @more
  end

  private

  # A profile is two chronological streams merged — what the account wrote, and
  # what it reposted, each ordered newest first. Both used to be loaded whole
  # and sorted in Ruby: every post an account had ever written, to return
  # twenty. That is the pathology N-6.8 removed from the ranked feed, measured
  # there at 763 ms, left untouched in the sibling service until finding 5 of
  # the 2026-08-18 review.
  #
  # To take the top N of a merge of two sorted streams you only ever need the
  # top N of each, so each side asks for exactly the rows this page could
  # contain, plus one. That one extra row also answers "is there another page?"
  # without a COUNT — the same trick the ranked archive uses, and the reason
  # this is bounded by the page rather than by the account's history.
  #
  # Identifiers first, objects second, for the reason ranked_feed.rb records:
  # sorting model objects means loading rows that are then discarded. Here the
  # reposter never needs loading at all — on a profile it is always the account
  # whose profile this is.
  #
  # A profile needs no *window*: it is chronological, so it needs only a LIMIT.
  # ADR 0011's "profiles never had a window and still do not" is a statement
  # about ranking, and stays true.
  def page_entries
    @page_entries ||= begin
      reach = (@page + 1) * PAGE_SIZE + 1

      written = @user.posts.top_level
                     .order(created_at: :desc, id: :desc)
                     .limit(reach)
                     .pluck(:id, :created_at)
                     .map { |id, at| [ at, id, false ] }

      reposted = @user.reposts.where(post_id: Post.top_level.select(:id))
                      .order(created_at: :desc, id: :desc)
                      .limit(reach)
                      .pluck(:post_id, :created_at)
                      .map { |post_id, at| [ at, post_id, true ] }

      merged = (written + reposted).sort_by { |at, id, _| [ -at.to_f, -id ] }
      page = merged.drop(@page * PAGE_SIZE).first(PAGE_SIZE + 1)
      @more = page.size > PAGE_SIZE
      page.first(PAGE_SIZE)
    end
  end

  # One query for the page's posts. An entry naming a row that has since been
  # deleted is dropped rather than rendered, the same way the ranked feed
  # handles it — the ordering is a snapshot taken a moment earlier.
  def hydrate(entries)
    return [] if entries.empty?

    posts = Post.where(id: entries.map { |_at, id, _| id }).for_rendering.index_by(&:id)

    entries.filter_map do |sort_time, post_id, reposted|
      post = posts[post_id]
      next if post.nil?

      FeedItem.new(
        post: post,
        reposter: (@user if reposted),
        sort_time: sort_time,
        score: 0
      )
    end
  end
end
