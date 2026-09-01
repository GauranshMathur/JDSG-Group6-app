module ApplicationHelper
  def render_body_with_hashtags(body)
    escaped = ERB::Util.html_escape(body)
    linked = escaped.gsub(Post::HASHTAG_REGEX) do |match|
      tag_name = Tag.normalize(Regexp.last_match(1))
      %(<a href="#{tag_path(tag_name)}" class="hashtag">#{match}</a>)
    end
    linked.html_safe
  end
end
