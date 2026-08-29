class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  before_action :authenticate_request

  attr_reader :current_user

  private

  def authenticate_request
    auth = request.headers['Authorization'].to_s
    if auth =~ /\ABearer\s+(.+)\z/
      token = Regexp.last_match(1)
      begin
        payload, = JWT.decode(token, CarbideControl::JwtSigningKey.private_key.public_key, true, { algorithm: 'RS256' })
        @current_user = User.find_by(id: payload['user_id']) if payload['scope'] == 'control:user'
      rescue JWT::DecodeError, JWT::ExpiredSignature
        @current_user = nil
      end
    end
    render json: { error: 'unauthorized' }, status: :unauthorized unless @current_user
  end

  # Skip auth on the login/signup endpoints — handled per-controller.
  def skip_authentication
    @current_user ||= nil
  end
end
