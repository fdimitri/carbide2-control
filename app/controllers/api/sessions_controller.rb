class Api::SessionsController < ApplicationController
  skip_before_action :authenticate_request, only: [:create, :signup]

  USER_TOKEN_TTL = 24 * 60 * 60  # 24h. Dashboard tokens, not workspace tokens.

  # POST /api/login {email, password}
  def create
    email, password = credentials_params
    user = User.find_by(email: email)
    if user&.valid_password?(password)
      render json: { token: mint_user_token(user), user: user_json(user) }
    else
      render json: { error: 'invalid credentials' }, status: :unauthorized
    end
  end

  # POST /api/signup {email, password}
  def signup
    email, password = credentials_params
    user = User.new(email: email, password: password)
    if user.save
      render json: { token: mint_user_token(user), user: user_json(user) }, status: :created
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/logout — JWT is stateless; client just drops the token.
  def destroy
    head :no_content
  end

  private

  def credentials_params
    source = params[:user] || params[:session] || params
    email = source[:email].to_s.downcase.strip
    password = source[:password].to_s
    [email, password]
  end

  def mint_user_token(user)
    payload = {
      iss:     'carbide-control',
      sub:     "user:#{user.id}",
      aud:     'control:dashboard',
      iat:     Time.now.to_i,
      exp:     Time.now.to_i + USER_TOKEN_TTL,
      user_id: user.id,
      scope:   'control:user'
    }
    JWT.encode(payload, CarbideControl::JwtSigningKey.private_key, 'RS256', { kid: CarbideControl::JwtSigningKey.kid })
  end

  def user_json(user)
    { id: user.id, email: user.email }
  end
end
