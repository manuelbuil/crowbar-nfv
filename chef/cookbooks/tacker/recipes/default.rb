#
# Cookbook Name: tacker
# Recipe:: default
#
# Copyright 2016, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

ha_enabled = false

git "/tmp/tacker" do
  repository "https://github.com/trozet/tacker.git"
  reference "SFC_colorado"
  action :sync
end

git "/tmp/tackerclient" do
  repository "https://github.com/trozet/python-tackerclient.git"
  reference "SFC_refactor"
  action :sync
end

db = "mysql"

if db == "mysql"
  include_recipe "tacker::db_mysql"
  node[@cookbook_name][:db][:sql_connection] = "mysql://tacker"\
                                               ":tacker@127.0.0.1/tacker"
else
  include_recipe "tacker::db_postgre"
  node[@cookbook_name][:db][db_conn_name] = "#{db_settings[:url_scheme]}://"\
                                            "#{db_user}:#{db_pass}@#"\
                                            "{db_settings[:address]}/"\
                                            "#{db_name}"
  unless sql_address_name.nil?
    node[@cookbook_name][:db][sql_address_name] = sql_address
  end
end

# Registering the service in keystone

api_port = node[:tacker][:api][:service_port]
tacker_protocol = node[:tacker][:api][:protocol]
my_public_host = CrowbarHelper.get_host_for_public_url(
  node, node[:tacker][:api][:protocol] == "https", ha_enabled
)
my_admin_host = CrowbarHelper.get_host_for_admin_url(node, ha_enabled)

keystone_settings = KeystoneHelper.keystone_settings(node, @cookbook_name)

register_auth_hash = { user: keystone_settings["admin_user"],
                       password: keystone_settings["admin_password"],
                       tenant: keystone_settings["admin_tenant"] }

keystone_register "tacker wakeup keystone" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  action :wakeup
end

keystone_register "register tacker user" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  user_password keystone_settings["service_password"]
  tenant_name keystone_settings["service_tenant"]
  action :add_user
end

keystone_register "give tacker user access" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  tenant_name keystone_settings["service_tenant"]
  role_name "admin"
  action :add_access
end

keystone_register "register tacker service" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  service_name "tacker"
  service_type "servicevm"
  service_description "Openstack Tacker Service"
  action :add_service
end

keystone_register "register tacker endpoint" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  endpoint_service "tacker"
  endpoint_region keystone_settings["endpoint_region"]
  endpoint_publicURL "#{tacker_protocol}://#{my_public_host}:#{api_port}/"
  endpoint_adminURL "#{tacker_protocol}://#{my_admin_host}:#{api_port}/"
  endpoint_internalURL "#{tacker_protocol}://#{my_admin_host}:#{api_port}/"
  action :add_endpoint_template
end

## Install the tacker client package

package "install pip" do
  package_name "python-pip"
end

execute "install client" do
  command "pip install ."
  cwd "/tmp/tackerclient"
end

## Install the tacker server package

execute "install server" do
  command "pip install ."
  cwd "/tmp/tacker"
end

## Add tacker group and user

group "tacker" do
  action :create
end

user "tacker" do
  comment "adding tacker user"
  gid "tacker"
end

## Create directories /etc/tacker, /var/log/tacker, /var/lib/tacker

directory "/var/log/tacker" do
  owner "tacker"
  group "tacker"
  mode "0750"
  action :create
end

directory "/var/lib/tacker" do
  owner "root"
  group "root"
  mode "0750"
  action :create
end

directory "/etc/tacker" do
  owner "root"
  group "root"
  mode "0750"
  action :create
end

## Create /etc/tacker.conf
heat_protocol = node[:heat][:api][:protocol]
heat_server = node[:heat][:elements][:'heat-server']
heat_port = node[:heat][:api][:port]

heat_uri = heat_protocol + "://" + heat_server[0] + ":" + heat_port.to_s + "/v1"

# rabbitmq_settings = CrowbarOpenStackHelper.rabbitmq_settings(node, "tacker")

template "/etc/tacker/tacker.conf" do
  source "tacker.conf.erb"
  owner "root"
  group node[:tacker][:service_group]
  mode "0640"
  variables(
    bind_host: my_admin_host,
    bind_port: api_port,
    rabbit_settings: CrowbarOpenStackHelper.rabbitmq_settings(node, "tacker"),
    keystone_settings: keystone_settings,
    connection: node[@cookbook_name][:db][:sql_connection],
    heat_uri: heat_uri,
    # infra_driver=opendaylight
    # username=admin
    # ip=192.168.0.2
    # password=admin
    ip: node[:ipaddress],
    # port=8282
    port: node[:opendaylight][:port]
  )
end

template "/etc/tacker/api-paste.ini" do
  source "api-paste.ini.erb"
  owner "root"
  group node[:tacker][:service_group]
  mode "0640"
end

template "/root/tackerc" do
  source "tackerc.erb"
  owner "root"
  group node[:tacker][:service_group]
  mode "0640"
  variables(
    keystone_settings: keystone_settings
  )
end

## Start the service

bash "start tacker" do
  user "root"
  retries 3
  retry_delay 2
  code <<-EOH
    /usr/bin/python /usr/bin/tacker-server \
    --config-file=/etc/tacker/tacker.conf \
    --verbose --log-file=/var/log/tacker/tacker-server.log &
  EOH
end
