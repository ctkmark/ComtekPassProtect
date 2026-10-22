module Admin
  class UsersController < ::AdminController
    def index
      load_users
      @new_user = User.new
    end

    # Existing administrators can provision staff without opening registration.
    # SMTP invitations are not sent: the administrator securely shares the
    # initial password, and the new user changes it from Account settings.
    def create
      role = params.dig(:user, :role).to_s
      unless %w[standard admin].include?(role)
        redirect_to admin_users_path, alert: "Choose a valid account role."
        return
      end

      attributes = params.require(:user).permit(:email, :password, :password_confirmation)
      @new_user = User.new(attributes)
      @new_user.email = @new_user.email.to_s.strip.downcase
      @new_user.admin = role == "admin"
      @new_user.skip_confirmation_notification! if @new_user.respond_to?(:skip_confirmation_notification!)
      @new_user.skip_confirmation! if @new_user.respond_to?(:skip_confirmation!)

      if @new_user.save
        redirect_to admin_users_path, status: :see_other,
          notice: "Account created. Share the initial password securely; ask the user to change it after signing in."
      else
        load_users
        render :index, status: :unprocessable_content
      end
    end

    def promote
      @user = User.find(params[:id])

      begin
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(["UPDATE users SET admin=true WHERE users.id=?", @user.id])
        )
        @user.reload

        redirect_to admin_users_path, notice: "#{@user.email} has been promoted to administrator."
      rescue => e
        redirect_to admin_users_path, alert: "Failed to promote #{@user.email} to administrator: #{e.message}"
      end
    end

    def revoke
      @user = User.find(params[:id])

      # Prevent admin from revoking their own admin privileges
      if @user == current_user
        redirect_to admin_users_path, alert: "You cannot revoke your own administrator privileges."
        return
      end

      begin
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(["UPDATE users SET admin=false WHERE users.id=?", @user.id])
        )
        @user.reload

        redirect_to admin_users_path, notice: "Administrator privileges have been revoked from #{@user.email}."
      rescue => e
        redirect_to admin_users_path, alert: "Failed to revoke administrator privileges from #{@user.email}: #{e.message}"
      end
    end

    def destroy
      @user = User.find(params[:id])

      # Prevent admin from deleting their own account
      if @user == current_user
        redirect_to admin_users_path, alert: _("You cannot delete your own account.")
        return
      end

      user_email = @user.email

      if @user.destroy
        redirect_to admin_users_path, notice: "User #{user_email} has been deleted."
      else
        error_message = @user.errors.full_messages.to_sentence.presence || "Unknown error"
        redirect_to admin_users_path, alert: "Failed to delete user #{user_email}: #{error_message}"
      end
    end

    private

    def load_users
      @admin_users = User.where(admin: true).order(:email)
      @regular_users = User.where(admin: [false, nil]).order(:email).page(params[:page]).per(25)
    end
  end
end
