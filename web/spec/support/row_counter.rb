# Counts the rows a block turns into model objects.
#
# The sibling to QueryCounter, and it exists because that one measures the axis
# that was not growing: ProfileFeed loaded an account's entire history to return
# twenty rows, in a *constant* number of queries. A query-count budget passes at
# twenty posts and at two hundred thousand. Rows read is what actually tracked
# the account's size — see docs/architecture-reviews/2026-08-18.md, finding 5.
module RowCounter
  def rows_instantiated_in(klass)
    counts = Hash.new(0)
    subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      counts[payload[:class_name]] += payload[:record_count].to_i
    end
    yield
    counts[klass.name]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
