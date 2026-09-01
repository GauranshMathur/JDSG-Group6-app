class ProfilesController < ApplicationController
  # Reading is public; only writing needs an account (F-2.5).
  allow_unauthenticated_access only: :show

  def show
    @user = User.find_by!(username: params[:username].downcase)
    @page = TimelinePage.from_feed(ProfileFeed.new(@user, page: TimelinePage.page_number(params[:page])),
                                   viewer: Current.user) { |page| profile_path(@user.username, page: page) }
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
