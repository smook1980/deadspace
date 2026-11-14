# frozen_string_literal: true

# Optional: dump the booted app's route table for `analyze --routes-json`. More exact than the
# static routes.rb parser (engines, custom DSL helpers), but needs a bootable app:
#
#   bin/rails runner script/dead_code/dump_routes.rb > tmp/routes.json
#   script/dead_code/analyze --routes-json tmp/routes.json
routes = Rails.application.routes.routes.map do |route|
  { controller: route.defaults[:controller], action: route.defaults[:action], path: route.path.spec.to_s }
end
puts JSON.pretty_generate(routes)
