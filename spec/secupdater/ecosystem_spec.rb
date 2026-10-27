require "secupdater"

RSpec.describe Secupdater::Ecosystem do
  describe ".resolve" do
    context "'rubygems'" do
      it "returns a Secupdater::Ecosystem::Rubygems instance" do
        expect(described_class.resolve("rubygems")).to be_a(Secupdater::Ecosystem::Rubygems)
        expect(described_class.resolve("RubyGems")).to be_a(Secupdater::Ecosystem::Rubygems)
      end
    end

    context "unknown ecosystem" do
      it "raises Secupdater::Error naming the ecosystem" do
        expect { described_class.resolve("npm") }.to raise_error(Secupdater::Error, "Unknown ecosystem: npm")
      end
    end
  end
end
