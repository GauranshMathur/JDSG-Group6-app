class ProfilesController < ApplicationController
  include TimelinePagination

  # Reading is public; only writing needs an account (F-2.5).
  allow_unauthenticated_access only: :show

  def show
    @user = User.find_by!(username: params[:username].downcase)
    feed = ProfileFeed.new(@user, page: page_param)
    @feed_items = feed.items
    @next_page = feed.next_page
    all_posts = @feed_items.map(&:post)
    @liked_post_ids = liked_post_ids_for(all_posts)
    @reposted_post_ids = reposted_post_ids_for(all_posts)
  end

  def edit
    @user = Current.user
  end

  # Edits are applied to a separate instance, not to Current.user. A rejected
  # edit leaves its invalid values on the object it was assigned to, and the
  # layout renders the signed-in identity from Current.user — so editing that
  # object in place would show the refused username in the sidebar, and point
  # the profile link at whoever actually holds it.
  def update
    @user = User.find(Current.user.id)

    if @user.update(profile_params)
      redirect_to profile_path(@user.username), notice: "Profile updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

    def profile_params
      params.require(:user).permit(:username, :display_name, :bio, :avatar)
    end
end
