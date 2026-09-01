class TagsController < ApplicationController
  allow_unauthenticated_access

  def show
    @tag = Tag.find_by!(name: Tag.normalize(params[:name]))
    @page = TimelinePage.from_scope(@tag.posts.timeline, after: params[:after],
                                    viewer: Current.user) { |cursor| tag_path(@tag.name, after: cursor) }
  end
end
