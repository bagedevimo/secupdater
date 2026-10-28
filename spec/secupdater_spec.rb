require "secupdater"

RSpec.describe Secupdater do
  describe ".build_logger" do
    it "logs to stderr, so log lines stay in order with errors when stdout is buffered" do
      expect { Secupdater.build_logger.warn("hello") }.to output("[WARN] hello\n").to_stderr
    end
  end
end
