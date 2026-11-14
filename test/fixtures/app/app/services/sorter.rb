class Sorter
  def self.sort(scope, field) = scope.public_send("sort_by_#{field}")
end
