class RepliesController < ApplicationController
  def create
    @parent = Post.find(params[:post_id])
    @reply = Current.user.posts.build(reply_params.merge(parent: @parent))

    if @reply.save
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to post_path(@parent) }
      end
    else
      @post = @parent
      @replies = @parent.replies.for_rendering.order(created_at: :asc, id: :asc)
      render "posts/show", status: :unprocessable_content
    end
  end

  private

  def reply_params
    params.require(:post).permit(:body)
  end
end
