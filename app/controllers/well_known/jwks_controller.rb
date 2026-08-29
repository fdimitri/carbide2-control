# Public JWKS endpoint (ADR-015). Serves the PUBLIC keys pods use to verify
# workspace tokens; never the private signing key. No auth.
class WellKnown::JwksController < ActionController::API
  def show
    render json: CarbideControl::JwtSigningKey.jwks
  end
end
