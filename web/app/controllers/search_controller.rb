class SearchController < ApplicationController
  allow_unauthenticated_access

  def show
    @query = params[:q].to_s.strip

    if @query.present?
      @page = TimelinePage.from_scope(Post.search(@query).timeline, after: params[:after],
                                      viewer: Current.user) { |cursor| search_path(q: @query, after: cursor) }
      @users = User.search(@query).limit(10)
    else
      @page = TimelinePage.empty
      @users = []
    end
  end
end
