require "rails_helper"

RSpec.describe DeadService do
  it { expect(described_class.new.call).to eq(1) }
end
