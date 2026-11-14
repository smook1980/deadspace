RSpec.describe Sorter do
  describe "#unused_method" do
    it { expect(Sorter).to respond_to(:sort) }
  end
end
