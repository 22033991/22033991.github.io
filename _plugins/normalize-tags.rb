#!/usr/bin/env ruby
#
# Treat tags as case-insensitive.
#
# Jekyll keys `site.tags` by the literal spelling, but tag pages are addressed
# by `slugify`, which downcases. So `Redis` and `redis` become two entries that
# both render to /tags/redis/ -- jekyll-archives then warns about the shared
# destination and one page silently overwrites the other.
#
# Collapse each case-variant group onto a single spelling before `site.tags` is
# built. Runs on :post_read, ahead of the generators that read it.

Jekyll::Hooks.register :site, :post_read do |site|
  counts = Hash.new(0)

  site.posts.docs.each do |post|
    Array(post.data['tags']).each { |tag| counts[tag.to_s] += 1 }
  end

  # Prefer the most-used spelling; on a tie prefer one that carries uppercase,
  # matching how this blog writes proper nouns (Java, Oracle, Spring Boot).
  canonical = counts.keys
                    .group_by { |tag| tag.downcase }
                    .transform_values do |spellings|
                      spellings.max_by { |s| [counts[s], s == s.downcase ? 0 : 1, s] }
                    end

  merged = canonical.reject { |slug, pick| counts.keys.count { |t| t.downcase == slug } < 2 }

  site.posts.docs.each do |post|
    tags = Array(post.data['tags'])
    next if tags.empty?

    post.data['tags'] = tags.map { |tag| canonical[tag.to_s.downcase] }.uniq
  end

  merged.each do |slug, pick|
    variants = counts.keys.select { |t| t.downcase == slug }.sort
    Jekyll.logger.info 'Tags:', "merged #{variants.inspect} -> #{pick.inspect}"
  end
end
