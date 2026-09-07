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

    # Issue #114: the Workspace CR bakes workspaceImage/workspaceImageTag at
    # create time from ENV['WORKSPACE_IMAGE']/['WORKSPACE_IMAGE_TAG']. When the
    # cluster switches from import to pull mode, those env vars gain a registry
    # prefix + new SHA, but existing CRs keep the stale create-time image — so
    # their pods pull `carbide2:<sha>` from Docker Hub and ImagePullBackOff.
    #
    # Re-stamp every existing CR from the CURRENT env so the import→pull switch
    # converges without a manual delete/recreate. Runs on every deploy (chained
    # into the migrate Job), so any later tag change also propagates.
    desc 'Re-stamp spec.workspaceImage(+Tag) on existing Workspace CRs from env'
    task workspace_images: :environment do
      image    = ENV.fetch('WORKSPACE_IMAGE', 'carbide2')
      image_tag = ENV.fetch('WORKSPACE_IMAGE_TAG', 'dev')
      patched = 0

      ControlProject.find_each do |project|
        cr = CarbideControl::WorkspaceApi.get(project)
        next if cr.nil?

        spec = (cr[:spec] || cr['spec']) || {}
        cur_image = spec[:workspaceImage] || spec['workspaceImage'] || 'carbide2'
        cur_tag   = spec[:workspaceImageTag] || spec['workspaceImageTag'] || 'dev'
        next if cur_image == image && cur_tag == image_tag

        CarbideControl::WorkspaceApi.merge_patch(
          project,
          spec: { workspaceImage: image, workspaceImageTag: image_tag }
        )
        patched += 1
        puts "[backfill] patched #{project.release_name}: workspaceImage=#{image}:#{image_tag}"
      end
      puts "[backfill] done: #{patched} CR(s) image-patched (target #{image}:#{image_tag})"
    end
  end
end
