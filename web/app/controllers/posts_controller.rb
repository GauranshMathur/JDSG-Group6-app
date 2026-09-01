class PostsController < ApplicationController
  # Reading is public; only writing needs an account. See docs/design-principles.md.
  allow_unauthenticated_access only: [ :index, :show ]

  # Authorisation by scoping, not by checking (F-3.5). Every write loads the post
  # through Current.user.posts, so someone else's row is simply not found and
  # raises. A fetch-then-compare would work until the day the comparison is
  # forgotten, and then it would expose the row instead of refusing it.
  before_action :set_own_post, only: %i[ edit update destroy ]

  def index
    @post = Post.new
    @page = TimelinePage.from_feed(RankedFeed.new(page: TimelinePage.page_number(params[:page])),
                                   viewer: Current.user) { |page| posts_path(page: page) }
  end

  def show
    @post = Post.for_rendering.find(params[:id])
    @replies = @post.replies.for_rendering.order(created_at: :asc, id: :asc)
    @reply = Post.new
    # The detail page is not a timeline — it is one post and its replies — but
    # it renders the same rows, so it borrows the same engagement lookup.
    @engagement = TimelinePage.new(
      items: ([ @post ] + @replies).map { |post| FeedItem.new(post: post, reposter: nil, sort_time: post.created_at, score: 0) },
      next_url: nil,
      viewer: Current.user
    )
  end

  def create
    @post = Current.user.posts.build(post_params)

    if @post.save
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to posts_path }
      end
    else
      @page = TimelinePage.from_feed(RankedFeed.new(page: 0), viewer: Current.user) { |page| posts_path(page: page) }
      render :index, status: :unprocessable_content
    end
  end

  def update
    if @post.update(post_params)
      redirect_to posts_path
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @post.destroy

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to posts_path }
    end
  end

  private

  def set_own_post
    @post = Current.user.posts.find(params[:id])
  end

  def post_params
    params.require(:post).permit(:body, images: [])
  end
end
