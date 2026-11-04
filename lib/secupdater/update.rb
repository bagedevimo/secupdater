module Secupdater
  class Update
    # What updating one vulnerable dependency on its own came to, before anything
    # is published. diff is every dependency the update moved, not just this one.
    Candidate = Struct.new(:dependency, :advisories, :status, :message, :level, :bump, :diff, :file_changes, keyword_init: true) do
      def name = dependency.name
      def resolved? = status == :resolved
    end

    attr_reader :logger, :ecosystem, :publisher, :original

    def initialize(logger, ecosystem, publisher: nil)
      @logger = logger
      @ecosystem = ecosystem
      @publisher = publisher
    end

    def call(advisories)
      @original = ecosystem.snapshot

      deps_needing_checking = advisories.group_by { it.name }

      missing = deps_needing_checking.keys - original.keys
      raise Secupdater::Error, "Advisories for dependencies not in the lockfile: #{missing.join(', ')}" if missing.any?

      candidates = deps_needing_checking.to_h do |name, dep_advisories|
        [name, try_update(original[name], dep_advisories)]
      end

      results = publish(candidates)

      publisher&.finish(deps_needing_checking.keys)&.each { logger.info it }

      deps_needing_checking.keys.to_h { [it, results.fetch(it)] }
    end

    private

    def try_update(dep, advisories)
      logger.info("starting update for #{dep.name}, #{advisories.length} advisories")

      levels = ecosystem.update_levels
      candidate = nil

      levels.each do |level|
        candidate = attempt_update(dep, advisories, level)
        return candidate if candidate.resolved?

        logger.debug "#{level} update: #{candidate.message}" unless level == levels.last
      end

      candidate
    rescue Secupdater::UnretryableUpdateFailed => e
      Candidate.new(dependency: dep, advisories:, status: :failed, message: "#{dep.name}: #{e.message}\n#{e.output}")
    end

    def attempt_update(dep, advisories, level)
      file_changes = ecosystem.try_update(dep.name, level:)
      diff = ecosystem.diff_snapshot(original, ecosystem.snapshot)
      bump = diff.detect { it.dependency.name == dep.name }
      attempt = { dependency: dep, advisories:, level:, bump:, diff:, file_changes: }

      return Candidate.new(**attempt, status: :unchanged, message: "#{dep.name} didn't update (stuck at #{dep.version})") unless bump

      unless fixes?(bump, advisories)
        return Candidate.new(**attempt, status: :unresolved, message: "#{dep.name} didn't update to a version that resolves the security warnings (went from #{bump.from} to #{bump.to})")
      end

      Candidate.new(**attempt, status: :resolved)
    rescue Secupdater::UnretryableUpdateFailed
      raise
    rescue Secupdater::UpdateCommandFailed => e
      Candidate.new(dependency: dep, advisories:, level:, status: :failed, message: "#{dep.name}: #{e.message}\n#{e.output}")
    ensure
      restore(file_changes)
    end

    # Publishes each update, with the advisories of any dependencies it absorbs.
    # If an absorbing update is declined, the dependencies it absorbed are
    # published without it (absorbing each other where they can).
    def publish(candidates)
      absorbed = absorptions(candidates)
      results = {}

      candidates.each_value do |candidate|
        next if absorbed.key?(candidate.name)

        covered = absorbed.filter_map { |name, absorber| candidates[name] if absorber == candidate.name }
        results[candidate.name] = publish_candidate(candidate, covered)
        next if covered.empty?

        if results[candidate.name] == :declined
          logger.info "#{candidate.name}'s update was declined, so updating #{covered.map(&:name).join(', ')} without it"
          results.merge!(publish(covered.to_h { [it.name, it] }))
        else
          covered.each { results[it.name] = :absorbed }
        end
      end

      results
    end

    # Which dependencies' updates go into another's MR, as { absorbed => absorber }.
    # A absorbs B when A's update also moves B to a version that fixes all of B's
    # advisories. The updates that cover the most go first, then by name so runs
    # agree, and each dependency ends up in only one MR.
    def absorptions(candidates)
      resolved = candidates.values.select(&:resolved?)
      covers = resolved.to_h do |candidate|
        [candidate.name, candidates.values.select { it != candidate && covers?(candidate, it) }.map(&:name)]
      end

      absorbed = {}
      covers.sort_by { |name, names| [-names.length, name] }.each do |name, names|
        next if absorbed.key?(name)

        names.each do |other|
          absorbed[other] = name unless absorbed.key?(other) || absorbed.value?(other)
        end
      end
      absorbed
    end

    def covers?(candidate, other)
      bump = candidate.diff.detect { it.dependency.name == other.name }
      bump && (bump.to.nil? || fixes?(bump, other.advisories))
    end

    def fixes?(bump, advisories)
      advisories.all? do |advisory|
        advisory.patched_versions.any? { ecosystem.satisfies_requirement?(bump.to, it) }
      end
    end

    def publish_candidate(candidate, covered)
      unless candidate.resolved?
        if candidate.status == :failed
          logger.error candidate.message
        else
          logger.warn candidate.message
        end
        return candidate.status
      end

      log_resolution(candidate, covered)

      return :resolved unless publisher

      status, message = publisher.call(ecosystem, candidate.bump, candidate.advisories + covered.flat_map(&:advisories), candidate.file_changes)
      logger.warn message if message
      status
    rescue Secupdater::PublishFailed => e
      logger.error "#{candidate.name}: #{e.message}"
      :failed
    end

    def log_resolution(candidate, covered)
      bump = candidate.bump
      upgrade = "upgrading #{candidate.name} from #{bump.from} to #{bump.to} (#{candidate.level})"

      candidate.advisories.each { logger.info "#{upgrade} would resolve #{it}" }

      covered.each do |other|
        other_bump = candidate.diff.detect { it.dependency.name == other.name }
        moves = other_bump.to ? "moves #{other.name} from #{other_bump.from} to #{other_bump.to}" : "removes #{other.name}"
        other.advisories.each { logger.info "#{upgrade} #{moves}, which would resolve #{it}" }
      end
    end

    def restore(file_changes)
      file_changes&.each do |change|
        if change.original_content
          File.write(change.filename, change.original_content)
        else
          File.delete(change.filename)
        end
      end
    end
  end
end
