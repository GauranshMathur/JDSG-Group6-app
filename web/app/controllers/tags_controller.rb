class TagsController < ApplicationController
  allow_unauthenticated_access

  def show
    @tag = Tag.find_by!(name: params[:name].downcase)
    @page = TimelinePage.from_scope(@tag.posts.timeline, after: params[:after],
                                    viewer: Current.user) { |cursor| tag_path(@tag.name, after: cursor) }
  end
end
