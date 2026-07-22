module Orchestrator
  # View-facing join between worker activities and the acceptance criteria
  # they address, so the run page can nest workers under their criterion
  # instead of listing them in a separate, unrelated panel. Uses the same
  # AcceptanceCriterionStep provenance edge (lineage_key -> criterion)
  # ChaperoneTrigger already joins through -- see project_memory/chaperone
  # work earlier for why lineage_key alone isn't a stable enough key on
  # its own but this join is.
  module AcceptanceCriteriaWorkers
    module_function

    UNASSIGNED = :unassigned

    def group(run_id:, activities:)
      lineage_keys = activities.filter_map { |activity| activity[:assignment_lineage_key] }.uniq
      criteria_by_lineage = AcceptanceCriterionStep
        .where(run_id: run_id, lineage_key: lineage_keys)
        .group_by(&:lineage_key)
        .transform_values { |steps| steps.map(&:acceptance_criterion_id).uniq }

      groups = Hash.new { |hash, key| hash[key] = [] }
      activities.each do |activity|
        criterion_ids = criteria_by_lineage[activity[:assignment_lineage_key]]
        if criterion_ids.blank?
          groups[UNASSIGNED] << activity
        else
          criterion_ids.each { |criterion_id| groups[criterion_id] << activity }
        end
      end
      groups
    end
  end
end
