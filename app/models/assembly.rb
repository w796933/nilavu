##
## Copyright [2013-2015] [Megam Systems]
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
require 'json'

class Assembly < BaseFascade

include MarketplaceHelper

  attr_reader :by_cattypes
  attr_reader :tosca_type
  attr_reader :components

  DEFAULT_TOSCA_PREFIX = 'tosca'.freeze
  #this is a mutable string, if nothing exists then we use ubuntu
  DEFAULT_TOSCA_SUFFIX = 'ubuntu'.freeze
  def initialize()
    @by_cattypes = {}
    @inputs = []
    @components = []
    @app_list = []
    @operations = []
  end

  def show(api_params, &block)
    raw = api_request(api_params, ASSEMBLY, SHOW)
    dig_components(raw[:body], api_params)
    yield self  if block_given?
    return self
  end

  def update(api_params, &block)
    api_request(bld_update_params(api_params), ASSEMBLY, UPDATE)
    api_request(bld_exist_update_params(api_params), ASSEMBLY, UPDATE) if api_params.has_key?(:bind_app_flag) #FOR BIND APP
    yield self if block_given?
    return self
  end

  def bld_update_params(params)
    asm = empty_assembly
    params = params.merge({"policymembers" => "#{params[:bind_type].split(':')[0]}"}) if params.has_key?(:bind_type)
    asm["policies"] = bld_policies(params) if params.has_key?(:bind_type)
    asm[:email] = params["email"]
    asm[:api_key] = params["api_key"]
    asm["id"] = "#{params[:bind_type].split(':')[1]}"
    asm
  end

  #FOR BIND APP
  def bld_exist_update_params(params)
    asm = empty_assembly
    params = params.merge({"policymembers" => "#{params[:bindapp].split(':')[0]}"}) if params.has_key?(:bindapp)
    asm["policies"] = bld_exist_policies(params) if params.has_key?(:bindapp)
    asm[:email] = params["email"]
    asm[:api_key] = params["api_key"]
    asm["id"] = "#{params[:bindapp].split(':')[1]}"
    asm
  end

  def build(params)
    mkp = JSON.parse(params["mkp"])

    bld_toscatype(mkp)
    bld_components(params) unless mkp["cattype"] == Assemblies::TORPEDO
    bld_inputs(params)
    bld_operations(params)

    params = params.merge({"policymembers" => "#{params[:assemblyname]}.#{params[:domain]}/#{params[:componentname]}"})

    [{
        "name"=>"#{params[:assemblyname]}",
        "tosca_type"=> "#{tosca_type}",
        "components"=> components,
        "requirements"=> @requirements,
        "policies"=>bld_policies(params),
        "inputs"=> @inputs,
        "outputs"=>[],
        "operations"=>[],
        "status"=> Assemblies::LAUNCHING,
      }]

  end

  private

  def empty_assembly
    {
      "name"=>nil,
      "tosca_type"=> nil,
      "components"=> [],
      "requirements"=> [],
      "policies"=>[],
      "inputs"=> [],
      "outputs"=>[],
      "operations"=>[],
      "status" => nil,
    }
  end

  def bld_toscatype(mkp)
    tosca_suffix = DEFAULT_TOSCA_SUFFIX
    tosca_suffix = "#{mkp["predef"]}" unless mkp["cattype"] != Assemblies::TORPEDO
    @tosca_type = DEFAULT_TOSCA_PREFIX +  ".#{mkp["cattype"].downcase}.#{tosca_suffix}"
  end

  ##For a vm, there is no component to start with, hence this is skipped.
  def bld_components(params)
    @components = Components.new.build(params)
  end

  def bld_policies(params)
    com = []
    if params.has_key?(:bind_type) && params[:bind_type] != "Unbound service"
      value = {
        :name=>"bind policy",
        :ptype=>"colocated",
        :members=>[
          params["policymembers"]
        ]
      }
    com << value
    end
    com
  end

  #FOR BIND APP
  def bld_exist_policies(params)
    com = []
    if params.has_key?(:bindapp) && params[:bindapp] != "Unbound service"
      value = {
        :name=>"bind policy",
        :ptype=>"colocated",
        :members=>[
          params["policymembers"]
        ]
      }
    com << value
    end
    com
  end

  #In future lot of inputs add this method
  def bld_inputs(params)

    mkp = JSON.parse(params["mkp"])
    @inputs << {"key" => "domain", "value" => params[:domain]} if params.has_key?(:domain)
    @inputs << {"key" => "sshkey", "value" => params[:ssh_keypair_name]} if params[:ssh_keypair_name]
    @inputs << {"key" => "provider", "value" => params[:provider]} if params.has_key?(:provider)
    @inputs << {"key" => "endpoint", "value" => params[:endpoint]} if params.has_key?(:endpoint)
    @inputs << {"key" => "cpu", "value" => params[:cpu]} if params.has_key?(:cpu)
    @inputs << {"key" => "ram", "value" => params[:ram]} if params.has_key?(:ram)
    @inputs << {"key" => "version", "value" => params[:version]} if mkp["cattype"] == Assemblies::TORPEDO
  end

  def bld_operations(params)
    @operations << {
        "operation_type" => "CI",
        "description" => "Continous Integration",
        "operation_requirements" => bld_ci_requirements(params),
    }
  end


  def bld_ci_requirements(params)
    mkp = JSON.parse(params["mkp"])
    op = []
    op <<  {"key" => "type", "value" => set_repotype(mkp["cattype"]) }
    op <<  {"key" => "enabled","value" => enable_ci(mkp["cattype"], params["radio_app_scm"])}
    op <<  {"key" => "source","value" => params["source"] || ""}
    op <<  {"key" => "token","value" => params["scmtoken"] || ""}
    op <<  {"key" => "username", "value" => params["scmowner"] || ""}
    op <<  {"key" => "url", "value" => params["source"] || ""}
    op
  end

  #recursively dig assembly by populating components.
  def dig_components(tmp_assembly_collection, api_params)
    tmp_assembly_collection.map do |one_assembly|
      a0 = one_assembly.components.map do |one_component|
        if !one_component.empty?
          one_component = Components.new.show(api_params.merge({"id" => one_component})).components
        else
          nil
        end
      end
      one_assembly.components.replace(a0)
      @by_cattypes = @by_cattypes.merge({ want_catkey(one_assembly.tosca_type) => one_assembly})
    end
    Rails.logger.debug ">-- ASC: START"
    Rails.logger.debug "#{@by_cattypes}"
    Rails.logger.debug "> ASC: END"
  end

  #match the tosca type APP, SERVICE, MICROSERVICES, TORPEDO from the string tosca.dew.ubuntu.
  #if there is no match, then send out an error
  def want_catkey(tmp_tosca_type)

    c0 = Assemblies::CATTYPES.select {|cat|  cat unless cat.downcase != tmp_tosca_type.split(".")[1]}
    raise MissingAPIArgsError, "Supported cat types are #{CATTYPES}." if c0.nil?
    c0.join
  end

end
