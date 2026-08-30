# frozen_string_literal: true

# One-shot backfills for existing clusters that predate a CR spec field.
#
#   rails carbide:backfill:workspace_uuids
#     -> merge-patch spec.projectUuid onto every Workspace CR that lacks it,
#        sourced from the matching ControlProject row by projectId.

namespace :carbide do
  namespace :backfill do
    desc 'Add spec.projectUuid to existing Workspace CRs that lack it'
    task workspace_uuids: :environment do
      patched = 0
      ControlProject.find_each do |project|
        next if project.uuid.blank?

        cr = CarbideControl::WorkspaceApi.get(project)
        next if cr.nil?

        spec = (cr[:spec] || cr['spec']) || {}
        next if (spec[:projectUuid] || spec['projectUuid']).present?

        CarbideControl::WorkspaceApi.merge_patch(project, spec: { projectUuid: project.uuid })
        patched += 1
        puts "[backfill] patched #{project.release_name}: projectUuid=#{project.uuid}"
      end
      puts "[backfill] done: #{patched} CR(s) patched"
    end
  end
end
