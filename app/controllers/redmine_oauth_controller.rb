# encoding: utf-8
# frozen_string_literal: true
#
# Redmine plugin OAuth
#
# Karel Pičman <karel.picman@kontron.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'account_controller'
require 'jwt'

class RedmineOauthController < AccountController

  def oauth
    session['back_url'] = params['back_url']
    case Setting.plugin_redmine_oauth['oauth_name']
    when 'Azure AD'
      redirect_to oauth_client.auth_code.authorize_url(redirect_uri: oauth_callback_url, scope: 'user:email')
    else
      flash['error'] = l(:oauth_invalid_provider)
      redirect_to signin_path
    end
  rescue Exception => e
    Rails.logger.error e.message
    flash['error'] = e.message
    redirect_to signin_path
  end

  def oauth_callback
    raise Exception.new(l(:notice_access_denied)) if params['error']
    case Setting.plugin_redmine_oauth['oauth_name']
    when 'Azure AD'
      token = oauth_client.auth_code.get_token(params['code'], redirect_uri: oauth_callback_url)
      user_info = JWT.decode(token.token, nil, false).first
      email = user_info['unique_name']
    else
      raise Exception.new(l(:oauth_invalid_provider))
    end
    if email
      try_to_login email, user_info
    else
      raise Exception.new(l(:oauth_no_verified_email))
    end
  rescue Exception => e
    Rails.logger.error e.message
    flash['error'] = e.message
    redirect_to signin_path
  end

  private

  def try_to_login(email, info)
    params['back_url'] = session['back_url']
    session.delete(:back_url)
    user = User.joins(:email_addresses).where(email_addresses: { address: email, is_default: true })
     .first_or_initialize
    if user.new_record?
      # Self-registration off
      redirect_to(home_url) && return unless Setting.self_registration?
      # Create on the fly
      firstname, lastname = info['name'].split(' ') if info['name'].present?
      firstname ||= info['given_name']
      lastname ||= info['family_name']
      user.firstname = firstname
      user.lastname = lastname
      user.mail = email
      login = info['login']
      login ||= info['unique_name']
      user.login = login
      user.random_password
      user.register
      case Setting.self_registration
      when '1'
        register_by_email_activation(user) do
          onthefly_creation_failed user
        end
      when '3'
        register_automatically(user) do
          onthefly_creation_failed user
        end
      else
        register_manually_by_administrator(user) do
          onthefly_creation_failed user
        end
      end
    else
      # Existing record
      if user.active?
        successful_authentication user
      else
        account_pending user
      end
    end
  end

  def oauth_client
    return @client if @client
    site = Setting.plugin_redmine_oauth['site']&.chomp('/')
    raise(Exception.new(l(:oauth_invalid_provider))) unless site
    @client = case Setting.plugin_redmine_oauth['oauth_name']
              when 'Azure AD'
                OAuth2::Client.new(
                  Setting.plugin_redmine_oauth['client_id'],
                  Setting.plugin_redmine_oauth['client_secret'],
                  site: site,
                  authorize_url: '/' + Setting.plugin_redmine_oauth['tenant_id'] + '/oauth2/authorize',
                  token_url: '/' + Setting.plugin_redmine_oauth['tenant_id'] + '/oauth2/token')
              else
                raise Exception.new(l(:oauth_invalid_provider))
              end
  end

end
