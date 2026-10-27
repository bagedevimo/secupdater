module Secupdater
  class Ecosystem
    def self.ecosystem_name = raise NotImplementedError
    def ecosystem_name = self.class.ecosystem_name

    def manifest_paths = raise NotImplementedError
    def run_update(names, level) = raise NotImplementedError
    def snapshot = raise NotImplementedError
    def diff_snapshot = raise NotImplementedError
    def parse_advisories(io) = raise NotImplementedError
    def satisfies_requirement?(version, requirement) = raise NotImplementedError

    def update_levels = [:patch, :minor, :major]

    def self.resolve(name)
      klass = self.subclasses.detect { it.ecosystem_name.downcase == name.downcase }
      raise Secupdater::Error, "Unknown ecosystem: #{name}" unless klass
      klass.new
    end

    def try_update(names, level:)
      before = read_manifests
      run_update(names, level)
      after = read_manifests

      manifest_paths.filter_map do |path|
        next if before[path] == after[path]

        type = if before[path].nil? then "create" elsif after[path].nil? then "delete" else "update" end
        FileChange.new(path, type, after[path], before[path])
      end
    end

    private

    def read_manifests
      manifest_paths.to_h { [it, File.exist?(it) ? File.read(it) : nil] }
    end
  end
end

require_relative "ecosystem/rubygems"

