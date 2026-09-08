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

    # ──────────────────────────────────────────────────────────────────────────
    # COMPAT SHIM — remove post-1.0. See fdimitri/carbide2#114 and #118.
    #
    # The Workspace CR freezes workspaceImage/Tag (and shell.imageRepo/Tag) at
    # create time. A workspace created before a consume:import → consume:pull
    # switch (or before the registry prefix was wired) keeps a bare image, so
    # its pod pulls `carbide2:<sha>` from Docker Hub and ImagePullBackOffs.
    #
    # This backfill re-stamps the image fields from the control plane's CURRENT
    # env / resolved settings so existing workspaces converge without a manual
    # delete+recreate. It is a deliberate pre-1.0 compatibility affordance, NOT
    # the long-term reconcile story — delete this once 1.0 no longer needs to
    # converge workspaces created under the old wiring.
    # ──────────────────────────────────────────────────────────────────────────
    desc 'Re-stamp workspace + shell image fields on existing CRs from current config'
    task workspace_images: :environment do
      ws_image    = ENV.fetch('WORKSPACE_IMAGE', 'carbide2')
      ws_tag      = ENV.fetch('WORKSPACE_IMAGE_TAG', 'dev')
      patched     = 0

      ControlProject.find_each do |project|
        cr = CarbideControl::WorkspaceApi.get(project)
        next if cr.nil?

        spec = (cr[:spec] || cr['spec']) || {}
        patch = {}

        cur_ws_image = spec[:workspaceImage] || spec['workspaceImage']
        cur_ws_tag   = spec[:workspaceImageTag] || spec['workspaceImageTag']
        if cur_ws_image != ws_image || cur_ws_tag != ws_tag
          patch[:workspaceImage]    = ws_image
          patch[:workspaceImageTag] = ws_tag
        end

        # Shell image: converge to what shell_spec_for would stamp (the resolved
        # per-project repo/tag), not the raw env — the model is the source of
        # truth for any per-workspace override.
        shell       = spec[:shell] || spec['shell'] || {}
        shell_repo  = shell[:imageRepo]  || shell['imageRepo']
        shell_tag   = shell[:imageTag]   || shell['imageTag']
        want_repo   = project.effective_shell_image_repo
        want_tag    = project.effective_shell_image_tag
        if shell_repo != want_repo || shell_tag != want_tag
          patch[:shell] = { imageRepo: want_repo, imageTag: want_tag }
        end

        next if patch.empty?

        CarbideControl::WorkspaceApi.merge_patch(project, spec: patch)
        patched += 1
        puts "[backfill] patched #{project.release_name}: #{patch.keys.join(', ')}"
      end
      puts "[backfill] done: #{patched} CR(s) image-patched"
    end
  end
end
