# Cursor pagination over a timeline-ordered scope, shared by every page that
# renders one — the feed, profiles, and later the tag pages. See ADR 0002 for
# why it is a cursor and not a page number.
module TimelinePagination
  PAGE_SIZE = 20

  private

    # The one place a page number is read off the query string, so it is the
    # one place a bad one is refused. Both feed controllers previously carried
    # the same unvalidated expression, and so carried the same defect: a
    # negative page reached `entries.drop(-20)`, which raises — a 500 on the
    # feed and on every profile, reachable by typing a URL.
    #
    # Anything that is not a page number reads as the first page rather than an
    # error: `to_i` is 0 for nil and for "banana", and the floor catches "-1".
    # There is no ceiling — a page past the end is a legitimate question with
    # an empty answer, and both feeds already answer it that way.
    def page_param
      [ params[:page].to_i, 0 ].max
    end

    # Loaded here rather than left for the view, because next_cursor_for asks
    # for its size first. On an unloaded relation that size is a separate COUNT
    # query, and the rows are then fetched again to render — two round trips for
    # one page of posts. See docs/latency.md.
    def page_of_posts(scope)
      cursor = Post.parse_cursor(params[:after])
      scope = scope.older_than(*cursor) if cursor
      scope.limit(PAGE_SIZE).load
    end

    # Only offer a "load older" link when this page filled up. A short page
    # means the end of the timeline has been reached.
    def next_cursor_for(posts)
      posts.last.cursor if posts.size == PAGE_SIZE
    end

    def liked_post_ids_for(posts)
      return Set.new unless Current.user

      Current.user.likes.where(post_id: posts.map(&:id)).pluck(:post_id).to_set
    end

    def reposted_post_ids_for(posts)
      return Set.new unless Current.user

      Current.user.reposts.where(post_id: posts.map(&:id)).pluck(:post_id).to_set
    end
end
