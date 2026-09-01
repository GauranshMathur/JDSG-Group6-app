# The ranking formula, in one place.
#
# It was written twice: here, and again in script/scaling-curve, with a comment
# ("the ranking, as RankedFeed#score computes it") as the only thing binding
# them. A comment cannot fail. Finding 9 of the 2026-08-18 architecture review.
#
# Deliberately a plain module with no Rails dependency, so the benchmark script
# can require it directly without booting the application — which is the reason
# the copy existed.
module Ranking
  # Engagement over age, with a repost counted double because it carries a post
  # to another timeline. The +1 keeps a post with no engagement above zero so
  # that recency alone can still rank it; the +2 hours stops a brand-new post
  # dividing by nearly nothing and dominating everything.
  #
  # The exponent is the decay: 1.5 is steeper than linear, so a day-old post
  # with modest engagement loses to a fresh one, and gentler than squaring,
  # which would empty the feed of anything not posted in the last few hours.
  def self.score(likes:, reposts:, replies:, age_hours:)
    engagement = likes + (reposts * 2) + replies
    (engagement + 1).to_f / ((age_hours + 2)**1.5)
  end

  # Hours between two times, floored at zero — a clock that has gone backwards
  # must not produce a negative age and an enormous score.
  def self.age_hours(at, now)
    ((now - at) / 3600.0).clamp(0, Float::INFINITY)
  end
end
