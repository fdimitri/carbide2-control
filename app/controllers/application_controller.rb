class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  before_action :authenticate_request

  attr_reader :current_user, :current_token_payload

  private

  def authenticate_request
    auth = request.headers['Authorization'].to_s
    if auth =~ /\ABearer\s+(.+)\z/
      token = Regexp.last_match(1)
      begin
        @current_token_payload, = JWT.decode(token, CarbideControl::JwtSigningKey.private_key.public_key, true, { algorithm: 'RS256' })
        if @current_token_payload['scope'] == 'control:user'
          sub = @current_token_payload['sub'].to_s
          uuid = sub.start_with?('user:') ? sub.delete_prefix('user:') : nil
          @current_user = uuid && User.find_by(uuid: uuid)
        end
      rescue JWT::DecodeError, JWT::ExpiredSignature
        @current_user = nil
        @current_token_payload = nil
      end
    end
    render json: { error: 'unauthorized' }, status: :unauthorized unless @current_user
  end

  # Skip auth on the login/signup endpoints — handled per-controller.
  def skip_authentication
    @current_user ||= nil
  end
end
