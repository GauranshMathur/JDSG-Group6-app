class ProfileFeed
  PAGE_SIZE = 20

  def initialize(user, page: 0)
    @user = user
    @page = page
  end

  def items
    @items ||= build_feed
  end

  def next_page
    @page + 1 if items.size == PAGE_SIZE
  end

  private

  def build_feed
    posts = @user.posts.top_level.for_rendering.to_a
    # The nested post: hash is Post.for_rendering's chain respelled — an
    # includes cannot name a scope on a nested association. If for_rendering
    # changes, this is the one copy to change with it.
    reposts = @user.reposts.eager_load(:user, post: :user)
                   .includes(
                     user: { avatar_attachment: :blob },
                     post: { user: { avatar_attachment: :blob }, images_attachments: :blob }
                   )
                   .where(post: Post.top_level).to_a

    feed = []

    posts.each do |post|
      feed << FeedItem.new(post: post, reposter: nil, sort_time: post.created_at, score: 0)
    end

    reposts.each do |repost|
      feed << FeedItem.new(post: repost.post, reposter: repost.user, sort_time: repost.created_at, score: 0)
    end

    feed
      .sort_by { |item| [ -item.sort_time.to_f, -item.post.id ] }
      .drop(@page * PAGE_SIZE)
      .first(PAGE_SIZE)
  end
end
