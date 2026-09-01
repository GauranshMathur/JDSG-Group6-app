class PostsController < ApplicationController
  include TimelinePagination

  # Reading is public; only writing needs an account. See docs/design-principles.md.
  allow_unauthenticated_access only: [ :index, :show ]

  # Authorisation by scoping, not by checking (F-3.5). Every write loads the post
  # through Current.user.posts, so someone else's row is simply not found and
  # raises. A fetch-then-compare would work until the day the comparison is
  # forgotten, and then it would expose the row instead of refusing it.
  before_action :set_own_post, only: %i[ edit update destroy ]

  def index
    @post = Post.new
    feed = RankedFeed.new(page: page_param)
    @feed_items = feed.items
    @next_page = feed.next_page
    all_posts = @feed_items.map(&:post)
    @liked_post_ids = liked_post_ids_for(all_posts)
    @reposted_post_ids = reposted_post_ids_for(all_posts)
  end

  def show
    @post = Post.for_rendering.find(params[:id])
    @replies = @post.replies.for_rendering.order(created_at: :asc, id: :asc)
    @reply = Post.new
    @liked_post_ids = liked_post_ids_for([ @post ] + @replies)
    @reposted_post_ids = reposted_post_ids_for([ @post ] + @replies)
  end

  def create
    @post = Current.user.posts.build(post_params)

    if @post.save
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to posts_path }
      end
    else
      feed = RankedFeed.new(page: 0)
      @feed_items = feed.items
      @next_page = feed.next_page
      render :index, status: :unprocessable_content
    end
  end

  def edit
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
