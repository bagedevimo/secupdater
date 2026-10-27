require "secupdater"
require "secupdater/publisher"

RSpec.describe Secupdater::Publisher do
  describe ".new" do
    it "can't be instantiated directly" do
      expect { described_class.new }.to raise_error(NotImplementedError)
    end
  end
end
