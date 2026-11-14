RSpec.describe Post do
  it { expect(Post.new.only_tested).to eq(1) }
  it { DeadService.new.call }
end
