# Lists the SPA client builds available to this control-plane pod so the
# dashboard's picker can offer a choice. Selecting one is a client concern: it
# reloads with `?client=<family>@<sha>`, which SpaController resolves and pins.
#
# Public (no auth): the loader must be able to enumerate builds before a user
# is signed in, exactly like the workspace pod's equivalent endpoint.
class Api::ClientsController < ApplicationController
  skip_before_action :authenticate_request

  def index
    reg = ClientRegistry.new
    families = reg.families.map do |name|
      { name:, default_sha: reg.newest(name)&.sha, builds: reg.builds(name).map(&:as_json_h) }
    end
    render json: { default: reg.default_family, families: }
  end
end
