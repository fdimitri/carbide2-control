# Lists the SPA client builds available to this control-plane pod so the
# dashboard's picker can offer a choice. Selecting one is a client concern: it
# reloads with `?client=<family>@<sha>`, which SpaController resolves and pins.
#
# Public (no auth): the loader must be able to enumerate builds before a user
# is signed in, exactly like the workspace pod's equivalent endpoint. Scoped to
# THIS pod's own family (carbide2-control): the loader only serves its own
# family, so listing another would just offer builds that fail.
class Api::ClientsController < ApplicationController
  skip_before_action :authenticate_request

  def index
    reg = ClientRegistry.new
    fam = reg.default_family
    builds = reg.builds(fam).map(&:as_json_h)
    families = fam ? [{ name: fam, default_sha: reg.newest(fam)&.sha, builds: }] : []
    render json: { default: fam, families: }
  end
end
