class Api::SessionsController < ApplicationController
  skip_before_action :authenticate_request, only: [:create, :signup]

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
    CarbideControl::UserTokenIssuer.issue!(user)
  end

  def user_json(user)
    { id: user.id, email: user.email }
  end
end
